import AppKit
import UniformTypeIdentifiers

// Bring an existing list in from AniList (public profile, by name) or MyAnimeList (its XML export).
// Adds to My list; never changes the status of a show that's already there.
enum Import {
    struct Item { var anime: Anime; var status: Status?; var favourite = false }

    static func status(anilist s: String) -> Status? {
        ["CURRENT": .watching, "REPEATING": .watching, "PAUSED": .planning, "PLANNING": .planning, "COMPLETED": .finished][s] // dropped: left out
    }

    static func status(mal s: String) -> Status? {
        ["Watching": .watching, "On-Hold": .planning, "Plan to Watch": .planning, "Completed": .finished][s]
    }

    static func anilist(user: String) async throws -> [Item] {
        // ponytail: only the first 50 favourites; page through them if someone has more.
        let d = try await AniList.query("query($u:String){c:MediaListCollection(userName:$u,type:ANIME){lists{entries{status media{isAdult \(AniList.cardFields)}}}} u:User(name:$u){favourites{anime(perPage:50){nodes{isAdult \(AniList.cardFields)}}}}}",
                                        ["u": user])
        var items: [String: Item] = [:]
        for e in (d.d("c")?.a("lists") ?? []).flatMap({ $0.a("entries") }) {
            guard let m = e.d("media"), m["isAdult"] as? Bool != true, let s = status(anilist: e.s("status") ?? "") else { continue }
            let a = AniList.parse(m)
            items[a.id] = Item(anime: a, status: s)
        }
        for m in d.d("u")?.d("favourites")?.d("anime")?.a("nodes") ?? [] where m["isAdult"] as? Bool != true {
            let a = AniList.parse(m)
            items[a.id, default: Item(anime: a, status: nil)].favourite = true
        }
        return Array(items.values)
    }

    // MAL's export: <anime><series_animedb_id>21</series_animedb_id>…<my_status>Watching</my_status></anime>, sometimes gzipped.
    static func mal(file: URL) async throws -> (items: [Item], missing: Int) {
        var data = try Data(contentsOf: file)
        if data.starts(with: [0x1F, 0x8B]) { data = try gunzip(file) }
        let xml = String(decoding: data, as: UTF8.self)
        var wanted: [Int: Status] = [:]
        for block in xml.components(separatedBy: "<anime>").dropFirst() {
            guard let id = tag("series_animedb_id", in: block).flatMap(Int.init), let s = status(mal: tag("my_status", in: block) ?? "") else { continue }
            wanted[id] = s
        }
        var items: [Item] = []
        let ids = Array(wanted.keys)
        for start in stride(from: 0, to: ids.count, by: 50) { // AniList knows each show's MAL id; 50 per request
            let d = try await AniList.query("query($ids:[Int]){Page(perPage:50){media(idMal_in:$ids,type:ANIME){idMal isAdult \(AniList.cardFields)}}}",
                                            ["ids": Array(ids[start..<min(start + 50, ids.count)])])
            for m in d.d("Page")?.a("media") ?? [] where m["isAdult"] as? Bool != true {
                if let mal = m["idMal"] as? Int, let s = wanted[mal] { items.append(Item(anime: AniList.parse(m), status: s)) }
            }
        }
        return (items, wanted.count - items.count)
    }

    static func tag(_ name: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return s[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gunzip(_ file: URL) throws -> Data {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", file.path]
        p.standardOutput = out
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d
    }

    @MainActor static func pickMALFile() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose your MyAnimeList export (animelist_….xml or .xml.gz)"
        panel.allowedContentTypes = [.xml, UTType("org.gnu.gnu-zip-archive")].compactMap { $0 }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
