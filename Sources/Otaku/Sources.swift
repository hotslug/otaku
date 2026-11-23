import CryptoKit
import Foundation

// Data sources: AniList (primary), Kitsu (fallback), TMDB (optional, needs a key: per-country availability).

typealias J = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func d(_ k: String) -> J? { self[k] as? J }
    func a(_ k: String) -> [J] { self[k] as? [J] ?? [] }
    func s(_ k: String) -> String? { (self[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func i(_ k: String) -> Int? { self[k] as? Int }
}

struct StreamLink: Codable, Hashable { var site: String; var url: URL; var note: String? }

struct Anime: Codable, Hashable, Identifiable {
    var id: String // "anilist:16498" or "kitsu:7442"
    var title: String
    var native: String?
    var synopsis: String
    var start: String?
    var end: String?
    var status: String?
    var episodes: Int?
    var format: String?
    var score: Int? // 0-100
    var popularity: Int?
    var genres: [String]
    var studio: String?
    var poster: URL?
    var banner: URL?
    var links: [StreamLink]
    var titles: [String] // English + romaji, for matching on other sites
    var tvSeasons: Int?
    var seasonsMore = false // the sequel chain went further than we looked
    var year: String? { start.map { String($0.prefix(4)) } }
    var isMovie: Bool { format == "Movie" }
}

struct Home: Codable { var popular: [Anime]; var trending: [Anime] }

struct Candidate: Codable, Hashable, Identifiable { var id: Int; var name: String; var year: String? }

struct Watch: Codable {
    var tmdbId: Int? // nil = no match
    var name = ""
    var year: String?
    var seasons: Int?
    var networks: [String] = []
    var stream: [String] = []
    var buy: [String] = []
    var link: URL?
    var candidates: [Candidate]
}

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    static func json(_ r: URLRequest) async throws -> J {
        let (data, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? J
        else { throw URLError(.badServerResponse) }
        return j
    }

    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
}

// Last good answer per request, so the app still shows something when every source is down.
enum Cache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Otaku")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(_ key: String) -> URL {
        dir.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
}

func plain(_ html: String) -> String {
    var t = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
    t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (e, c) in ["&quot;": "\"", "&#039;": "'", "&lt;": "<", "&gt;": ">", "&mdash;": "—", "&rsquo;": "’", "&nbsp;": " ", "&amp;": "&"] {
        t = t.replacingOccurrences(of: e, with: c)
    }
    return t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}

func nice(_ s: String) -> String {
    switch s.uppercased() {
    case "RELEASING", "CURRENT": return "Airing"
    case "TV", "OVA", "ONA": return s.uppercased()
    case "TV_SHORT": return "TV short"
    default: return s.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
    }
}

enum AniList {
    static let fields = "id title{english romaji native} description(asHtml:false) startDate{year month day} endDate{year month day} status episodes format averageScore popularity genres studios(isMain:true){nodes{name}} coverImage{large} bannerImage externalLinks{site url type notes}"

    static func query(_ q: String, _ vars: J = [:]) async throws -> J {
        var r = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["query": q, "variables": vars])
        guard let d = try await Net.json(r).d("data") else { throw URLError(.badServerResponse) }
        return d
    }

    static func home() async throws -> Home {
        func page(_ name: String, _ sort: String) -> String { "\(name): Page(perPage:30){media(type:ANIME,isAdult:false,sort:\(sort)){\(fields)}}" }
        let d = try await query("{\(page("popular", "POPULARITY_DESC")) \(page("trending", "TRENDING_DESC"))}")
        return Home(popular: d.d("popular")?.a("media").map(parse) ?? [], trending: d.d("trending")?.a("media").map(parse) ?? [])
    }

    static func search(_ q: String) async throws -> [Anime] {
        let d = try await query("query($q:String){Page(perPage:30){media(type:ANIME,isAdult:false,search:$q,sort:SEARCH_MATCH){\(fields)}}}", ["q": q])
        return d.d("Page")?.a("media").map(parse) ?? []
    }

    // AniList returns empty relations past 2 levels of nesting, so the chain is loaded 2 hops at a time.
    static let rel2 = "id format relations{edges{relationType node{id format relations{edges{relationType node{id format}}}}}}"

    static func detail(_ id: String) async throws -> Anime {
        let d = try await query("query($id:Int){Media(id:$id){\(fields) \(rel2)}}", ["id": Int(id.dropFirst("anilist:".count)) ?? 0])
        guard let m = d.d("Media") else { throw URLError(.badServerResponse) }
        var a = parse(m)
        var chain = Chain()
        chain.add([m])
        // ponytail: up to 3 follow-up requests (~8 more hops); "N+" beyond that.
        for _ in 0..<3 where !chain.frontier.isEmpty {
            let ids = chain.frontier
            chain.frontier = []
            guard let more = try? await query("query($ids:[Int]){Page(perPage:50){media(id_in:$ids){\(rel2)}}}", ["ids": ids]) else {
                chain.frontier = ids
                break
            }
            chain.add(more.d("Page")?.a("media") ?? [])
        }
        a.tvSeasons = chain.tv.count
        a.seasonsMore = !chain.frontier.isEmpty
        return a
    }

    // Counts TV entries linked by sequel/prequel (through movies/OVAs too).
    struct Chain {
        var seen = Set<Int>(), tv = Set<Int>(), frontier: [Int] = [] // frontier: reached, but links not loaded yet

        mutating func add(_ roots: [J]) { for r in roots { walk(r, root: true) } }

        mutating func walk(_ n: J, root: Bool) {
            guard let id = n.i("id") else { return }
            guard seen.insert(id).inserted || root else { return }
            if ["TV", "TV_SHORT"].contains(n.s("format") ?? "") { tv.insert(id) }
            guard let edges = n.d("relations")?.a("edges") else { frontier.append(id); return }
            for e in edges where ["SEQUEL", "PREQUEL"].contains(e.s("relationType") ?? "") {
                if let c = e.d("node") { walk(c, root: false) }
            }
        }
    }

    static func date(_ d: J?) -> String? {
        guard let y = d?.i("year") else { return nil }
        guard let m = d?.i("month") else { return "\(y)" }
        return String(format: "%d-%02d", y, m) + (d?.i("day").map { String(format: "-%02d", $0) } ?? "")
    }

    static func parse(_ m: J) -> Anime {
        let t = m.d("title") ?? [:]
        return Anime(
            id: "anilist:\(m.i("id") ?? 0)",
            title: t.s("english") ?? t.s("romaji") ?? "?",
            native: t.s("native"),
            synopsis: plain(m.s("description") ?? ""),
            start: date(m.d("startDate")), end: date(m.d("endDate")),
            status: m.s("status").map(nice), episodes: m.i("episodes"), format: m.s("format").map(nice),
            score: m.i("averageScore"), popularity: m.i("popularity"),
            genres: m["genres"] as? [String] ?? [],
            studio: m.d("studios")?.a("nodes").first?.s("name"),
            poster: m.d("coverImage")?.s("large").flatMap(URL.init(string:)),
            banner: m.s("bannerImage").flatMap(URL.init(string:)),
            links: m.a("externalLinks").filter { $0.s("type") == "STREAMING" }.compactMap { l in
                l.s("url").flatMap(URL.init(string:)).map { StreamLink(site: l.s("site") ?? $0.host ?? "", url: $0, note: l.s("notes")) }
            },
            titles: [t.s("english"), t.s("romaji")].compactMap { $0 })
    }
}

enum Kitsu {
    static func get(_ path: String) async throws -> J {
        var r = URLRequest(url: URL(string: "https://kitsu.io/api/edge/" + path)!)
        r.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        return try await Net.json(r)
    }

    static func list(_ j: J) -> [Anime] { j.a("data").map { parse($0, j.a("included")) } }

    static func home() async throws -> Home {
        async let p = get("anime?sort=-userCount&page%5Blimit%5D=20")
        async let t = get("trending/anime?limit=20")
        return try await Home(popular: list(p), trending: list(t))
    }

    static func search(_ q: String) async throws -> [Anime] {
        list(try await get("anime?page%5Blimit%5D=20&filter%5Btext%5D=" + Net.enc(q)))
    }

    static func detail(id: String) async throws -> Anime {
        let j = try await get("anime/\(id.dropFirst("kitsu:".count))?include=streamingLinks.streamer")
        guard let d = j.d("data") else { throw URLError(.badServerResponse) }
        return parse(d, j.a("included"))
    }

    // Used when AniList is down and we only know the title.
    static func detail(title: String) async throws -> Anime {
        let j = try await get("anime?page%5Blimit%5D=1&include=streamingLinks.streamer&filter%5Btext%5D=" + Net.enc(title))
        guard let d = j.a("data").first else { throw URLError(.badServerResponse) }
        return parse(d, j.a("included"))
    }

    static func parse(_ a: J, _ included: [J]) -> Anime {
        let x = a.d("attributes") ?? [:]
        let t = x.d("titles") ?? [:]
        var streamers: [String: String] = [:]
        for s in included where s.s("type") == "streamers" { streamers[s.s("id") ?? ""] = s.d("attributes")?.s("siteName") }
        let mine = Set(a.d("relationships")?.d("streamingLinks")?.a("data").compactMap { $0.s("id") } ?? [])
        let links: [StreamLink] = included.filter { $0.s("type") == "streamingLinks" && mine.contains($0.s("id") ?? "") }.compactMap { l in
            guard var u = l.d("attributes")?.s("url") else { return nil }
            if !u.hasPrefix("http") { u = "https://" + u }
            guard let url = URL(string: u) else { return nil }
            return StreamLink(site: streamers[l.d("relationships")?.d("streamer")?.d("data")?.s("id") ?? ""] ?? url.host ?? u, url: url)
        }
        return Anime(
            id: "kitsu:\(a.s("id") ?? "0")",
            title: t.s("en") ?? x.s("canonicalTitle") ?? "?",
            native: t.s("ja_jp"),
            synopsis: x.s("synopsis") ?? "",
            start: x.s("startDate"), end: x.s("endDate"),
            status: x.s("status").map(nice), episodes: x.i("episodeCount"), format: x.s("subtype").map(nice),
            score: x.s("averageRating").flatMap(Double.init).map { Int($0.rounded()) },
            popularity: x.i("userCount"), genres: [], studio: nil,
            poster: x.d("posterImage")?.s("large").flatMap(URL.init(string:)),
            banner: x.d("coverImage")?.s("large").flatMap(URL.init(string:)),
            links: links,
            titles: [t.s("en"), x.s("canonicalTitle")].compactMap { $0 })
    }
}

enum TMDB {
    // Accepts either the short v3 "API key" or the long v4 "read access token".
    static func get(_ path: String, key: String) async throws -> J {
        let bearer = key.count > 40
        var r = URLRequest(url: URL(string: "https://api.themoviedb.org/3/" + path + (bearer ? "" : (path.contains("?") ? "&" : "?") + "api_key=" + Net.enc(key)))!)
        if bearer { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return try await Net.json(r)
    }

    // "Attack on Titan Season 3 Part 2" -> also try "Attack on Titan": TMDB keeps all seasons under one show.
    static func searchTerms(_ titles: [String]) -> [String] {
        var out: [String] = []
        for t in titles {
            let base = t.replacingOccurrences(of: #"(?i)\s*(\bseason\s*\d+|\d+(st|nd|rd|th)\s+season|\bpart\s*\d+|\bthe final season).*$"#, with: "", options: .regularExpression)
            for c in [t, base, base.components(separatedBy: ":")[0]] {
                let c = c.trimmingCharacters(in: .whitespaces)
                if !c.isEmpty, !out.contains(c) { out.append(c) }
            }
        }
        return out
    }

    // Search results, animated Japanese shows first.
    static func rank(_ results: [J]) -> [Candidate] {
        func score(_ r: J) -> Int {
            ((r["genre_ids"] as? [Int] ?? []).contains(16) ? 2 : 0) + (r.s("original_language") == "ja" ? 1 : 0)
        }
        return results.enumerated().sorted { (score($0.1), -$0.0) > (score($1.1), -$1.0) }.compactMap { _, r in
            r.i("id").map { Candidate(id: $0, name: r.s("name") ?? r.s("title") ?? "?", year: (r.s("first_air_date") ?? r.s("release_date")).map { String($0.prefix(4)) }) }
        }
    }

    // pick: a TMDB id the user chose, -1 = "none of these", nil = best guess.
    static func watch(for a: Anime, key: String, region: String, pick: Int?) async throws -> Watch {
        let kind = a.isMovie ? "movie" : "tv"
        var cands: [Candidate] = []
        for q in searchTerms(a.titles) where cands.isEmpty {
            cands = rank(try await get("search/\(kind)?query=\(Net.enc(q))", key: key).a("results"))
        }
        cands = Array(cands.prefix(10))
        guard let id = pick == -1 ? nil : pick ?? cands.first?.id else { return Watch(candidates: cands) }
        let d = try await get("\(kind)/\(id)?append_to_response=watch/providers", key: key)
        let r = d.d("watch/providers")?.d("results")?.d(region) ?? [:]
        func names(_ ks: String...) -> [String] {
            var out: [String] = []
            for k in ks { for p in r.a(k) { if let n = p.s("provider_name"), !out.contains(n) { out.append(n) } } }
            return out
        }
        return Watch(tmdbId: id, name: d.s("name") ?? d.s("title") ?? "", year: (d.s("first_air_date") ?? d.s("release_date")).map { String($0.prefix(4)) },
                     seasons: d.i("number_of_seasons"), networks: d.a("networks").compactMap { $0.s("name") },
                     stream: names("flatrate", "free", "ads"), buy: names("rent", "buy"),
                     link: r.s("link").flatMap(URL.init(string:)), candidates: cands)
    }
}

// A direct link to the service if AniList/Kitsu had one ("Netflix" matches "Netflix"), else nil.
func directLink(_ provider: String, _ links: [StreamLink]) -> URL? {
    func norm(_ s: String) -> String { s.lowercased().filter(\.isLetter) }
    let p = norm(provider)
    return links.first { let s = norm($0.site); return !s.isEmpty && (p.hasPrefix(s) || s.hasPrefix(p)) }?.url
}
