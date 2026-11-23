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
    var nextEpisode: Int?
    var nextAiring: Date?
    var related: [Related]? // details page only
    var recommended: [Anime]? // details page only
    var trailer: Trailer?
    var cast: [CastMember]? // details page only
    var year: String? { start.map { String($0.prefix(4)) } }
    var isMovie: Bool { format == "Movie" }
}

struct Row: Codable, Identifiable { var title: String; var items: [Anime]; var id: String { title } }
struct Home: Codable { var rows: [Row] }

struct Related: Codable, Hashable { var relation: String; var anime: Anime }

struct Person: Codable, Hashable { var name: String; var image: URL? }

struct CastMember: Codable, Hashable {
    var name: String
    var role: String // Main, Supporting, Background
    var image: URL?
    var japanese: Person?
    var english: Person?
}

struct Trailer: Codable, Hashable, Identifiable {
    var id: String
    var site: String // "youtube" or "dailymotion"
    var thumbnail: URL?

    var page: URL? { URL(string: site == "youtube" ? "https://www.youtube.com/watch?v=\(id)" : "https://www.dailymotion.com/video/\(id)") }
    // YouTube's widescreen still for the video (not every upload has one).
    var still: URL? { site == "youtube" ? URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg") : thumbnail }

    var embed: URL? {
        URL(string: site == "youtube" ? "https://www.youtube.com/embed/\(id)?autoplay=1&playsinline=1&rel=0" : "https://www.dailymotion.com/embed/video/\(id)?autoplay=1")
    }

    // YouTube won't play in a bare web view (error 153): the player must sit in a page that names the app.
    var playerHTML: String {
        """
        <html><body style="margin:0;background:#000;overflow:hidden">
        <iframe style="border:0;width:100vw;height:100vh" src="\(embed?.absoluteString ?? "")"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
          referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
    }
    var siteName: String { site == "youtube" ? "YouTube" : "Dailymotion" }
}

// Search filters. Values are AniList's names; Kitsu gets them translated.
struct Filters: Codable, Equatable {
    var genre: String?
    var year: Int?
    var format: String?
    var status: String?
    var sort = "POPULARITY_DESC"

    static let genres = ["Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy", "Horror", "Mahou Shoujo", "Mecha", "Music", "Mystery",
                         "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Supernatural", "Thriller"]
    static let formats = [("TV", "TV"), ("MOVIE", "Movie"), ("OVA", "OVA"), ("ONA", "ONA"), ("SPECIAL", "Special"), ("TV_SHORT", "TV short")]
    static let statuses = [("RELEASING", "Airing now"), ("FINISHED", "Finished"), ("NOT_YET_RELEASED", "Coming soon")]
    static let sorts = [("POPULARITY_DESC", "Most popular"), ("SCORE_DESC", "Best rated"), ("TRENDING_DESC", "Trending"), ("START_DATE_DESC", "Newest")]

    var active: Bool { genre != nil || year != nil || format != nil || status != nil || sort != Filters().sort }
    var key: String { [genre ?? "", year.map(String.init) ?? "", format ?? "", status ?? "", sort].joined(separator: "|") }
}

struct Airing: Codable, Hashable, Identifiable {
    var anime: Anime
    var episode: Int
    var at: Date
    var id: String { anime.id + "#\(episode)" }
}

enum Status: String, Codable, CaseIterable { case watching = "Watching", planning = "Plan to watch", finished = "Finished" }

struct Entry: Codable {
    var anime: Anime
    var status: Status?
    var favourite = false
}

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
    var direct: [String: URL] = [:] // service name -> straight to the show on that service
    var source = "JustWatch via TMDB"
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
    t = t.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression) // tidy spaces around line breaks
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
    static let fields = "id title{english romaji native} description(asHtml:false) startDate{year month day} endDate{year month day} status episodes format averageScore popularity genres studios(isMain:true){nodes{name}} coverImage{large} bannerImage externalLinks{site url type notes} nextAiringEpisode{episode airingAt} trailer{id site thumbnail}"

    static func query(_ q: String, _ vars: J = [:]) async throws -> J {
        var r = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["query": q, "variables": vars])
        guard let d = try await Net.json(r).d("data") else { throw URLError(.badServerResponse) }
        return d
    }

    // Lighter fields for start-page cards; the details page loads the rest.
    static let cardFields = "id title{english romaji native} startDate{year month day} status episodes format averageScore popularity genres coverImage{large} nextAiringEpisode{episode airingAt}"

    static func season(_ d: Date) -> (String, Int) {
        let c = Calendar.current.dateComponents([.month, .year], from: d)
        return (["WINTER", "SPRING", "SUMMER", "FALL"][(c.month! - 1) / 3], c.year!)
    }

    // All start-page rows in one request.
    static func home(now: Date = Date()) async throws -> Home {
        let (season, year) = season(now)
        let rows: [(String, String)] = [
            ("Trending now", "sort:TRENDING_DESC"),
            ("Most popular", "sort:POPULARITY_DESC"),
            ("Airing this season", "season:\(season),seasonYear:\(year),sort:POPULARITY_DESC"),
            ("Top rated", "sort:SCORE_DESC"),
            ("Coming soon", "status:NOT_YET_RELEASED,sort:POPULARITY_DESC"),
            ("Popular in Action", "genre:\"Action\",sort:POPULARITY_DESC"),
            ("Popular in Romance", "genre:\"Romance\",sort:POPULARITY_DESC"),
            ("Popular in Comedy", "genre:\"Comedy\",sort:POPULARITY_DESC"),
            ("Popular in Fantasy", "genre:\"Fantasy\",sort:POPULARITY_DESC"),
            ("Popular isekai", "tag:\"Isekai\",sort:POPULARITY_DESC"),
        ]
        let q = rows.enumerated().map { "r\($0.offset): Page(perPage:20){media(type:ANIME,isAdult:false,\($0.element.1)){\(cardFields)}}" }.joined(separator: " ")
        let d = try await query("{\(q)}")
        return Home(rows: rows.enumerated().map { Row(title: $0.element.0, items: d.d("r\($0.offset)")?.a("media").map(parse) ?? []) }.filter { !$0.items.isEmpty })
    }

    // Only filters that are set go into the query (AniList rejects some of them as null).
    static func search(_ q: String, _ f: Filters = Filters()) async throws -> [Anime] {
        var params = ["$sort:[MediaSort]"], args = ["sort:$sort"]
        // Matches ordered by the chosen sort (popular first by default): AniList's own "best match" can rank obscure shows
        // first, e.g. "demon slayer" -> Onigiri, whose Japanese title means demon slayer.
        var vars: [String: Any] = ["sort": [f.sort]]
        func add(_ name: String, _ type: String, _ arg: String, _ value: Any?) {
            guard let value else { return }
            params.append("$\(name):\(type)"); args.append("\(arg):$\(name)"); vars[name] = value
        }
        add("q", "String", "search", q.isEmpty ? nil : q)
        add("genre", "String", "genre", f.genre)
        add("format", "MediaFormat", "format", f.format)
        add("status", "MediaStatus", "status", f.status)
        add("from", "FuzzyDateInt", "startDate_greater", f.year.map { $0 * 10000 })
        add("to", "FuzzyDateInt", "startDate_lesser", f.year.map { ($0 + 1) * 10000 })
        let d = try await query("query(\(params.joined(separator: ","))){Page(perPage:40){media(type:ANIME,isAdult:false,\(args.joined(separator: ","))){\(cardFields)}}}", vars)
        return d.d("Page")?.a("media").map(parse) ?? []
    }

    // AniList returns empty relations past 2 levels of nesting, so the chain is loaded 2 hops at a time.
    static let rel2 = "id format relations{edges{relationType node{id format relations{edges{relationType node{id format}}}}}}"

    static func detail(_ id: String) async throws -> Anime {
        let d = try await query("query($id:Int){Media(id:$id){\(fields) \(rel2) related:relations{edges{relationType node{type isAdult bannerImage \(cardFields)}}} recommendations(sort:RATING_DESC,perPage:15){nodes{mediaRecommendation{type isAdult \(cardFields)}}} \(castFields)}}",
                                ["id": Int(id.dropFirst("anilist:".count)) ?? 0])
        guard let m = d.d("Media") else { throw URLError(.badServerResponse) }
        var a = parse(m)
        a.related = related(m.d("related")?.a("edges") ?? [])
        if a.banner == nil { a.banner = borrowedBanner(m.d("related")?.a("edges") ?? []) }
        a.cast = cast(m.d("characters")?.a("edges") ?? [])
        a.recommended = (m.d("recommendations")?.a("nodes") ?? []).compactMap { $0.d("mediaRecommendation") }
            .filter { $0.s("type") == "ANIME" && $0["isAdult"] as? Bool != true }.map(parse)
        var chain = Chain()
        chain.add([m])
        // ponytail: up to 5 follow-up requests (2 hops each; long series like Attack on Titan need 4); "N+" beyond that.
        for _ in 0..<5 where !chain.frontier.isEmpty {
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

    // No banner of its own: borrow one from the same series (season 1 for a season 2, the show for its movie...).
    static func borrowedBanner(_ edges: [J]) -> URL? {
        let order = ["PREQUEL", "PARENT", "SEQUEL", "SIDE_STORY", "ALTERNATIVE", "SPIN_OFF"]
        return edges.compactMap { e -> (Int, URL)? in
            guard let n = e.d("node"), n.s("type") == "ANIME", n["isAdult"] as? Bool != true,
                  let i = order.firstIndex(of: e.s("relationType") ?? ""), let u = n.s("bannerImage").flatMap(URL.init(string:)) else { return nil }
            return (i, u)
        }.min { $0.0 < $1.0 }?.1
    }

    // Anime only (no manga/novels), in watch order: prequels, sequels, then the rest.
    static let relationOrder = ["PREQUEL", "SEQUEL", "PARENT", "SIDE_STORY", "SPIN_OFF", "ALTERNATIVE", "SUMMARY", "CHARACTER", "OTHER", "COMPILATION", "CONTAINS"]

    static func related(_ edges: [J]) -> [Related] {
        edges.compactMap { e -> (Int, Related)? in
            guard let n = e.d("node"), n.s("type") == "ANIME", n["isAdult"] as? Bool != true, let r = e.s("relationType") else { return nil }
            let a = parse(n)
            let label = r == "SIDE_STORY" ? "Side story" : r == "SPIN_OFF" ? "Spin-off" : r == "PARENT" ? "Main story"
                : (r == "ALTERNATIVE" || r == "OTHER") && a.format == "Movie" ? "Movie" : nice(r)
            return (relationOrder.firstIndex(of: r) ?? relationOrder.count, Related(relation: label, anime: a))
        }
        .enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
    }

    // Counts TV entries linked by sequel/prequel (through movies/OVAs too).
    struct Chain {
        var seen = Set<Int>(), tv = Set<Int>(), frontier: [Int] = [] // frontier: reached, but links not loaded yet

        mutating func add(_ roots: [J]) { for r in roots { walk(r, root: true) } }

        mutating func walk(_ n: J, root: Bool) {
            guard let id = n.i("id") else { return }
            guard seen.insert(id).inserted || root else { return }
            if ["TV", "TV_SHORT"].contains(n.s("format") ?? "") { tv.insert(id) }
            // Missing or empty below the top: AniList sometimes leaves nested lists empty, so load it next round.
            guard let edges = n.d("relations")?.a("edges"), root || !edges.isEmpty else { frontier.append(id); return }
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
        var a = card(m)
        a.trailer = trailer(m.d("trailer"))
        return a
    }

    static func card(_ m: J) -> Anime {
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
            titles: [t.s("english"), t.s("romaji")].compactMap { $0 },
            nextEpisode: m.d("nextAiringEpisode")?.i("episode"),
            nextAiring: m.d("nextAiringEpisode")?.i("airingAt").map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    static let castFields = "characters(sort:[ROLE,RELEVANCE,ID],perPage:20){edges{role node{name{full} image{medium}} jp:voiceActors(language:JAPANESE,sort:[RELEVANCE,ID]){name{full} image{medium}} en:voiceActors(language:ENGLISH,sort:[RELEVANCE,ID]){name{full} image{medium}}}}"

    static func cast(_ edges: [J]) -> [CastMember] {
        func person(_ v: [J]) -> Person? {
            v.first.flatMap { p in p.d("name")?.s("full").map { Person(name: $0, image: p.d("image")?.s("medium").flatMap(URL.init(string:))) } }
        }
        return edges.compactMap { e in
            guard let n = e.d("node"), let name = n.d("name")?.s("full") else { return nil }
            return CastMember(name: name, role: nice(e.s("role") ?? ""), image: n.d("image")?.s("medium").flatMap(URL.init(string:)),
                              japanese: person(e.a("jp")), english: person(e.a("en")))
        }
    }

    static func trailer(_ t: J?) -> Trailer? {
        guard let t, let id = t.s("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, // some ids end in a tab
              let site = t.s("site"), ["youtube", "dailymotion"].contains(site) else { return nil }
        return Trailer(id: id, site: site, thumbnail: t.s("thumbnail").flatMap(URL.init(string:)))
    }

    // Every episode airing between two dates (a week is ~5 pages of 50).
    static func schedule(from: Date, to: Date) async throws -> [Airing] {
        var out: [Airing] = []
        for page in 1...10 {
            let d = try await query("query($p:Int,$a:Int,$b:Int){Page(page:$p,perPage:50){pageInfo{hasNextPage} airingSchedules(airingAt_greater:$a,airingAt_lesser:$b,sort:TIME){episode airingAt media{isAdult \(fields)}}}}",
                                    ["p": page, "a": Int(from.timeIntervalSince1970), "b": Int(to.timeIntervalSince1970)])
            let p = d.d("Page")
            for s in p?.a("airingSchedules") ?? [] {
                guard let m = s.d("media"), m["isAdult"] as? Bool != true, let ep = s.i("episode"), let at = s.i("airingAt") else { continue }
                out.append(Airing(anime: parse(m), episode: ep, at: Date(timeIntervalSince1970: TimeInterval(at))))
            }
            if p?.d("pageInfo")?["hasNextPage"] as? Bool != true { break }
        }
        return out
    }

    // For new-episode alerts: what aired for these shows in a time window, and each one's next episode.
    static func airing(ids: [Int], from: Date, to: Date) async throws -> (aired: [(id: Int, episode: Int)], next: [Int: (Int, Date)?]) {
        let d = try await query("query($ids:[Int],$a:Int,$b:Int){aired:Page(perPage:50){airingSchedules(mediaId_in:$ids,airingAt_greater:$a,airingAt_lesser:$b,sort:TIME){episode mediaId}} next:Page(perPage:50){media(id_in:$ids){id nextAiringEpisode{episode airingAt}}}}",
                                ["ids": ids, "a": Int(from.timeIntervalSince1970), "b": Int(to.timeIntervalSince1970)])
        let aired = d.d("aired")?.a("airingSchedules").compactMap { s in s.i("mediaId").flatMap { id in s.i("episode").map { (id: id, episode: $0) } } } ?? []
        var next: [Int: (Int, Date)?] = [:]
        for m in d.d("next")?.a("media") ?? [] {
            guard let id = m.i("id") else { continue }
            let n = m.d("nextAiringEpisode")
            next[id] = n?.i("episode").flatMap { ep in n?.i("airingAt").map { (ep, Date(timeIntervalSince1970: TimeInterval($0))) } }
        }
        return (aired, next)
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
        async let t = get("anime?filter%5Bstatus%5D=current&sort=-userCount&page%5Blimit%5D=20") // its trending list is stale
        return try await Home(rows: [Row(title: "Airing now", items: list(t)), Row(title: "Most popular", items: list(p))])
    }

    static func search(_ q: String, _ f: Filters = Filters()) async throws -> [Anime] {
        var p = ["page[limit]=20"]
        if !q.isEmpty { p.append("filter[text]=" + Net.enc(q)) } else { p.append(f.sort == "SCORE_DESC" ? "sort=-averageRating" : f.sort == "START_DATE_DESC" ? "sort=-startDate" : "sort=-userCount") }
        if let y = f.year { p.append("filter[seasonYear]=\(y)") }
        if let s = ["RELEASING": "current", "FINISHED": "finished", "NOT_YET_RELEASED": "upcoming"][f.status ?? ""] { p.append("filter[status]=" + s) }
        if let t = ["TV": "TV", "MOVIE": "movie", "OVA": "OVA", "ONA": "ONA", "SPECIAL": "special"][f.format ?? ""] { p.append("filter[subtype]=" + t) }
        return list(try await get("anime?" + p.joined(separator: "&").replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")))
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

// Movie of the Night's Streaming Availability API: per-country availability with direct links,
// and commercial use is allowed on every plan (TMDB's free key isn't). Keys from their own site or from RapidAPI both work.
enum MotN {
    static var viaRapid: Bool? // learned from the first request that works

    static func get(_ path: String, key: String) async throws -> Any {
        for rapid in viaRapid.map({ [$0] }) ?? [false, true] {
            var r = URLRequest(url: URL(string: (rapid ? "https://streaming-availability.p.rapidapi.com" : "https://api.movieofthenight.com/v4") + path)!)
            r.setValue(key, forHTTPHeaderField: rapid ? "X-RapidAPI-Key" : "X-API-Key")
            if rapid { r.setValue("streaming-availability.p.rapidapi.com", forHTTPHeaderField: "X-RapidAPI-Host") }
            let (data, resp) = try await Net.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403, viaRapid == nil { continue } // not this kind of key: try the other
            guard code == 200 else { throw URLError(.badServerResponse) }
            viaRapid = rapid
            return try JSONSerialization.jsonObject(with: data)
        }
        throw URLError(.userAuthenticationRequired)
    }

    // Best match first: animated, then closest start year.
    static func rank(_ shows: [J], year: Int?) -> [J] {
        func score(_ s: J) -> (Int, Int) {
            let anim = (s["genres"] as? [J] ?? []).contains { $0.s("id") == "animation" } ? 0 : 1
            let y = s.i("firstAirYear") ?? s.i("releaseYear") ?? 0
            return (anim, year.map { abs($0 - y) } ?? 0)
        }
        return shows.enumerated().sorted {
            let (a, b) = (score($0.1), score($1.1))
            return (a.0, a.1, $0.0) < (b.0, b.1, $1.0)
        }.map(\.1)
    }

    static func tmdbId(_ s: J) -> Int? { s.s("tmdbId")?.split(separator: "/").last.flatMap { Int($0) } } // "tv/1429"

    // Turns one show's options for a country into Watch's lists. Rent/buy/addon go under "Rent or buy".
    static func watch(from s: J, country: String, candidates: [Candidate]) -> Watch {
        var w = Watch(tmdbId: tmdbId(s) ?? -2, name: s.s("title") ?? "", year: (s.i("firstAirYear") ?? s.i("releaseYear")).map(String.init),
                      seasons: s.i("seasonCount"), candidates: candidates, source: "Movie of the Night")
        for o in (s["streamingOptions"] as? J)?.a(country) ?? [] {
            let svc = o.d("service")
            guard let name = svc?.s("name") ?? svc?.s("id")?.capitalized else { continue }
            let paid = ["rent", "buy", "addon"].contains(o.s("type") ?? "")
            if paid { if !w.buy.contains(name) { w.buy.append(name) } } else if !w.stream.contains(name) { w.stream.append(name) }
            if w.direct[name] == nil { w.direct[name] = (o.s("link") ?? svc?.s("homePage")).flatMap(URL.init(string:)) }
        }
        return w
    }

    static func watch(for a: Anime, key: String, region: String, pick: Int?) async throws -> Watch {
        let country = region.lowercased() == "uk" ? "gb" : region.lowercased()
        var shows: [J] = []
        for q in TMDB.searchTerms(a.titles) where shows.isEmpty {
            let path = "/shows/search/title?country=\(country)&show_type=\(a.isMovie ? "movie" : "series")&title=" + Net.enc(q)
            shows = rank(try await get(path, key: key) as? [J] ?? [], year: a.year.flatMap { Int($0) })
        }
        let cands = shows.prefix(10).compactMap { s in tmdbId(s).map { Candidate(id: $0, name: s.s("title") ?? "?", year: (s.i("firstAirYear") ?? s.i("releaseYear")).map(String.init)) } }
        if pick == -1 { return Watch(candidates: Array(cands), source: "Movie of the Night") }
        guard let s = pick.flatMap({ p in shows.first { tmdbId($0) == p } }) ?? shows.first else { return Watch(candidates: Array(cands), source: "Movie of the Night") }
        return watch(from: s, country: country, candidates: Array(cands))
    }
}

// A direct link to the service if AniList/Kitsu had one ("Netflix" matches "Netflix"), else nil.
func directLink(_ provider: String, _ links: [StreamLink]) -> URL? {
    func norm(_ s: String) -> String { s.lowercased().filter(\.isLetter) }
    let p = norm(provider)
    return links.first { let s = norm($0.site); return !s.isEmpty && (p.hasPrefix(s) || s.hasPrefix(p)) }?.url
}
