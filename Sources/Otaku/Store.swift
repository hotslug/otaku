import Foundation
import SwiftUI

enum Tab: String, CaseIterable {
    case discover = "Discover", list = "My list", schedule = "Schedule"
    var icon: String { ["Discover": "sparkles", "My list": "list.star", "Schedule": "calendar"][rawValue]! }
}

@MainActor final class Store: ObservableObject {
    static let shared = Store()

    @Published var tab = Tab.discover
    @Published var inMenuBar = UserDefaults.standard.object(forKey: "inMenuBar") as? Bool ?? true { didSet { UserDefaults.standard.set(inMenuBar, forKey: "inMenuBar") } }
    var scheduleDay = "" // the day the loaded week starts on

    // This week's episodes for shows on My list (favourites included).
    var myEpisodes: [Airing] { (schedule ?? []).filter { list[$0.anime.id] != nil }.sorted { $0.at < $1.at } }
    @Published var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark { // the night sky by default
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance"); appearance.apply() }
    }
    @Published var rowScroll: [String: ScrollPosition] = [:] // per row title
    @Published var rowX: [String: CGFloat] = [:] // how far each row is scrolled
    @Published var rowEnd: [String: CGFloat] = [:] // furthest it can scroll
    @Published var hoverRow: String?
    var rowWidth: [String: CGFloat] = [:] // visible width of each row, for paging to a highlighted card
    var gridCols = 1 // cards per line in the results grid, for ↑ ↓
    @Published var reveal: String? // row or card the arrow keys moved to: scrolled into view
    @Published var hoverCard: String?
    @Published var confirmRemove: Anime? // waiting for "Remove from My list?" to be answered
    @Published var detailWidth: CGFloat = 1000 // a show's page width; narrow puts the facts under the synopsis
    @Published var expandedLinks: Set<String> = [] // link lists showing "+N more" expanded
    @Published var schedule: [Airing]?
    @Published var onlyMine = UserDefaults.standard.bool(forKey: "onlyMine") { didSet { UserDefaults.standard.set(onlyMine, forKey: "onlyMine") } }
    @Published var alertsOn = UserDefaults.standard.object(forKey: "alertsOn") as? Bool ?? true { didSet { UserDefaults.standard.set(alertsOn, forKey: "alertsOn") } }
    @Published var list: [String: Entry] = Store.loadList() { didSet { saveList() } }

    @Published var home: Home?
    @Published var forYou: [Row] = [] // "Because you liked…" rows, from Favourites
    @Published var newForYou: [Anime] = [] // carousel: shows on My list with a new episode this week
    @Published var slide = 0 // carousel: the slide showing
    @Published var slideHover = false // carousel: held while the pointer is on it
    @Published var query = ""
    @Published var filters = Filters() { didSet { if filters != oldValue { Task { await search() } } } }
    @Published var results: [Anime]?
    @Published var searching = false
    @Published var playing: Trailer? // trailer shown in the player sheet
    @Published var englishCast = UserDefaults.standard.bool(forKey: "englishCast") { didSet { UserDefaults.standard.set(englishCast, forKey: "englishCast") } }
    @Published var resultsFor = ""
    @Published var path: [Anime] = []
    @Published var details: [String: Anime] = [:]
    @Published var watch: [String: Watch] = [:]
    @Published var fallback = false // AniList didn't answer, so this came from the backup (Kitsu)
    @Published var stale = false // showing saved data because every source failed
    @Published var error: String?
    @Published var tmdbKey = UserDefaults.standard.string(forKey: "tmdbKey") ?? "" {
        didSet { UserDefaults.standard.set(tmdbKey, forKey: "tmdbKey"); watch = [:] }
    }

    var key: String { tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    @Published var motnKey = UserDefaults.standard.string(forKey: "motnKey") ?? "" {
        didSet { UserDefaults.standard.set(motnKey, forKey: "motnKey"); watch = [:]; MotN.viaRapid = nil }
    }
    var motn: String { motnKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasWatchKey: Bool { !key.isEmpty || !motn.isEmpty }
    var region: String { Locale.current.region?.identifier ?? "US" }
    var regionName: String { Locale.current.localizedString(forRegionCode: region) ?? region }

    // Tries each source in order; saves the first answer, or falls back to the last saved one.
    func fetch<T: Codable>(_ cacheKey: String, _ sources: [() async throws -> T], main: Bool = true) async -> T? {
        let file = Cache.url(cacheKey)
        for (i, source) in sources.enumerated() {
            if let v = try? await source() {
                try? JSONEncoder().encode(v).write(to: file)
                if main { stale = false; error = nil; fallback = i > 0 }
                return v
            }
        }
        if let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode(T.self, from: d) {
            if main { stale = true }
            return v
        }
        if main { error = "Couldn't reach AniList or Kitsu, and nothing is saved for this yet." }
        return nil
    }

    func loadHome() async {
        if home == nil { home = await fetch("home-rows", [{ try await AniList.home() }, { try await Kitsu.home() }]) }
    }

    // Shows on My list whose last episode came out this week, newest first, with that episode's number.
    // ponytail: "this week" = the next episode is due within 7 days, so it assumes weekly shows; good enough for a headline.
    static func newEpisodes(_ list: [String: Entry], now: Date = Date()) -> [(id: String, episode: Int)] {
        list.values.filter { $0.status != .finished && ($0.status != nil || $0.favourite) && $0.anime.id.hasPrefix("anilist:") }
            .compactMap { e -> (String, Int, Date)? in
                guard let n = e.anime.nextEpisode, n > 1, let at = e.anime.nextAiring, at > now, at < now.addingTimeInterval(7 * 86400) else { return nil }
                return (e.anime.id, n - 1, at)
            }
            .sorted { $0.2 > $1.2 } // furthest next episode = the one that came out most recently
            .map { (id: $0.0, episode: $0.1) }
    }

    func loadNewForYou() async {
        let picks = Array(Self.newEpisodes(list).prefix(3))
        let ids = picks.compactMap { Int($0.id.dropFirst("anilist:".count)) }
        guard !ids.isEmpty else { newForYou = []; return }
        newForYou = await fetch("featured:" + ids.map(String.init).joined(separator: ","), [{ try await AniList.featured(ids: ids) }], main: false)
            ?? picks.compactMap { list[$0.id]?.anime }
    }

    // The start page carousel: your new episodes first, then trending shows that have a banner.
    var slides: [Slide] {
        let fresh = Dictionary(Self.newEpisodes(list).map { ($0.id, $0.episode) }, uniquingKeysWith: { a, _ in a })
        let mine = newForYou.map { Slide(anime: $0, note: fresh[$0.id].map { "Episode \($0) is out" } ?? "On your list") }
        let row = home?.rows.first
        let rest = (row?.items ?? []).enumerated()
            .filter { $0.element.banner != nil && !newForYou.map(\.id).contains($0.element.id) }
            .map { Slide(anime: $0.element, note: "\(row!.title) · #\($0.offset + 1)") }
        return Array((mine + rest).prefix(8))
    }

    // Discover's picture: the top search result, or the carousel.
    var discoverSlides: [Slide] {
        if let r = results { return r.first.map { [Slide(anime: $0, note: resultsFor.isEmpty ? "Most popular · " + resultsTitle : "Top result")] } ?? [] }
        return searching ? [] : slides
    }

    // My list's carousel: new episodes, then Watching, then Favourites; only shows with a banner.
    var listSlides: [Slide] {
        let fresh = Dictionary(Self.newEpisodes(list).map { ($0.id, $0.episode) }, uniquingKeysWith: { a, _ in a })
        func rank(_ e: Entry) -> Int { fresh[e.anime.id] != nil ? 0 : e.status == .watching ? 1 : e.favourite ? 2 : 3 }
        return list.values.filter { rank($0) < 3 }
            .sorted { (rank($0), $0.anime.title) < (rank($1), $1.anime.title) }
            .map { e in Slide(anime: art(e.anime), note: fresh[e.anime.id].map { "Episode \($0) is out" } ?? (e.status == .watching ? "Watching" : "Favourite")) }
            .filter { $0.anime.banner != nil }
            .prefix(8).map { $0 }
    }

    // The next episode to air: from My list if any, else anything.
    var upNext: Airing? {
        let now = Date()
        return myEpisodes.first { $0.at > now } ?? schedule?.filter { $0.at > now }.min { $0.at < $1.at }
    }

    // Whether this page starts with a big picture that runs up under the toolbar.
    var heroOnTop: Bool {
        guard path.isEmpty else { return false }
        switch tab {
        case .discover: return !discoverSlides.isEmpty
        case .list: return !listSlides.isEmpty
        case .schedule: return upNext != nil
        }
    }

    // Banners and synopses for My list (saved entries are cards, which have neither).
    @Published var listArt: [String: Anime] = [:]
    func art(_ a: Anime) -> Anime { listArt[a.id] ?? a }

    func loadListArt() async {
        let ids = list.keys.filter { $0.hasPrefix("anilist:") }.sorted().prefix(50).compactMap { Int($0.dropFirst("anilist:".count)) }
        guard !ids.isEmpty else { return }
        let found = await fetch("list-art", [{ try await AniList.featured(ids: Array(ids)) }], main: false) ?? []
        listArt = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // Start page rows: Trending, then the personal ones, then the rest.
    var discoverRows: [Row] { home.map { Array($0.rows.prefix(1) + forYou + $0.rows.dropFirst()) } ?? [] }

    var resultsTitle: String { resultsFor.isEmpty ? (filters.seasonTag.map(Filters.label) ?? "Filtered") : "Results for “\(resultsFor)”" }

    // My list as rows: Favourites, then each status, A-Z.
    var myListRows: [Row] {
        let entries = list.values.sorted { $0.anime.title.localizedCaseInsensitiveCompare($1.anime.title) == .orderedAscending }
        return ([Row(title: "★ Favourites", items: entries.filter(\.favourite).map(\.anime))]
            + Status.allCases.map { s in Row(title: s.rawValue, items: entries.filter { $0.status == s }.map(\.anime)) }).filter { !$0.items.isEmpty }
    }

    // Two favourites (picked at random, so the rows vary) -> their recommendations, minus shows already in My list.
    func loadForYou() async {
        let picks = Array(list.values.filter { $0.favourite && $0.anime.id.hasPrefix("anilist:") }.map(\.anime).shuffled().prefix(2))
        let rows = picks.isEmpty ? [] : await fetch("for-you:" + picks.map(\.id).sorted().joined(separator: ","),
                                                    [{ try await AniList.recommended(for: picks) }], main: false) ?? []
        forYou = rows.map { Row(title: $0.title, items: $0.items.filter { list[$0.id] == nil }) }.filter { $0.items.count >= 3 }
        if ProcessInfo.processInfo.environment["OTAKU_LOG"] != nil { FileHandle.standardError.write(Data("for you: \(forYou.map { "\($0.title) (\($0.items.count))" })\n".utf8)) }
    }

    // Runs for a search term, filters, or both.
    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces), f = filters
        guard !q.isEmpty || f.active else { results = nil; searching = false; return }
        searching = true
        if ProcessInfo.processInfo.environment["OTAKU_LOG"] != nil { FileHandle.standardError.write(Data("search: \(q.isEmpty ? "(filters)" : q)\n".utf8)) }
        let r = await fetch("search:\(q.lowercased()):\(f.key)", [{ try await AniList.search(q, f) }, { try await Kitsu.search(q, f) }]) ?? []
        guard q == query.trimmingCharacters(in: .whitespaces), f == filters else { return } // changed while loading
        searching = false
        results = r
        resultsFor = q
    }

    // "Surprise me": a random well-rated show that fits the current filters and isn't on My list yet, opened straight away.
    @Published var surprising = false

    func surprise() async {
        surprising = true
        defer { surprising = false }
        var f = filters
        f.sort = "POPULARITY_DESC" // known shows, so the surprise is a good one
        var pool: [Anime] = []
        for page in [Int.random(in: 1...5), 1] where pool.isEmpty { // a random page of the top 200; page 1 if the filters are narrow
            pool = ((try? await AniList.search("", f, page: page, minScore: 70)) ?? []).filter { list[$0.id] == nil }
        }
        if pool.isEmpty { pool = ((try? await Kitsu.search("", f)) ?? []).filter { list[$0.id] == nil } }
        guard let pick = pool.randomElement() else { error = "No surprise found for these filters."; return }
        tab = .discover
        path = [pick]
    }

    // Search as you type: waits for a short pause, so a word costs one request, not one per letter.
    var typing: Task<Void, Never>?

    func typed() {
        typing?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.isEmpty || q.count >= 2 else { return } // one letter: wait for more
        typing = Task {
            if !q.isEmpty { try? await Task.sleep(for: .milliseconds(550)) }
            guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespaces) else { return }
            if !q.isEmpty, q == resultsFor, results != nil { return } // already searched (e.g. Enter, then a click on a result)
            if !q.isEmpty, tab != .discover || !path.isEmpty { tab = .discover; path = [] } // typing elsewhere: show the results
            await search() // empty: back to filters only, or the start page
        }
    }

    func retry() async {
        error = nil; fallback = false
        if results != nil { await search() } else { home = nil; await loadHome() }
    }

    func loadDetail(_ a: Anime) async {
        if details[a.id] == nil {
            let title = a.titles.first ?? a.title
            var d = await fetch("detail:" + a.id, a.id.hasPrefix("kitsu:")
                ? [{ try await Kitsu.detail(id: a.id) }]
                : [{ try await AniList.detail(a.id) }, { try await Kitsu.detail(title: title) }]) ?? a
            if let t = d.trailer, await !t.alive() { d.trailer = nil } // checked before the page shows, so nothing jumps
            details[a.id] = d
        }
        await loadWatch(a)
    }

    // Movie of the Night first (direct links, fine for a paid app), TMDB as the fallback.
    func loadWatch(_ a: Anime) async {
        let key = key, motn = motn, region = region
        guard hasWatchKey, watch[a.id] == nil else { return }
        let pick = UserDefaults.standard.object(forKey: "tmdb." + a.id) as? Int
        var sources: [() async throws -> Watch] = []
        if !motn.isEmpty { sources.append { try await MotN.watch(for: a, key: motn, region: region, pick: pick) } }
        if !key.isEmpty { sources.append { try await TMDB.watch(for: a, key: key, region: region, pick: pick) } }
        watch[a.id] = await fetch("watch:\(a.id):\(region):\(pick ?? 0):\(motn.isEmpty ? "t" : "m")", sources, main: false)
    }

    func choose(_ a: Anime, _ tmdbId: Int) {
        UserDefaults.standard.set(tmdbId, forKey: "tmdb." + a.id)
        watch[a.id] = nil
        Task { await loadWatch(a) }
    }

    // MARK: My list. Saved in Application Support (not Caches: this is the user's data).

    nonisolated static let listFile: URL = {
        if let test = ProcessInfo.processInfo.environment["OTAKU_LIST"] { return URL(fileURLWithPath: test) } // for layout checks
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Otaku")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("list.json")
    }()

    nonisolated static func loadList(from file: URL = listFile) -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        if let l = try? JSONDecoder().decode([String: Entry].self, from: data) { return l }
        // Unreadable: keep it aside instead of overwriting it on the next save.
        try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))"))
        return [:]
    }

    func saveList() {
        try? JSONEncoder().encode(list).write(to: Self.listFile, options: .atomic)
    }

    func setStatus(_ a: Anime, _ s: Status?) {
        var e = list[a.id] ?? Entry(anime: a)
        e.status = s
        put(a.id, e)
        if s == .watching || s == .planning { Alerts.ask() }
    }

    func toggleFavourite(_ a: Anime) {
        var e = list[a.id] ?? Entry(anime: a)
        e.favourite.toggle()
        put(a.id, e)
    }

    // Import: shows already on My list keep their status; favourites only get added.
    @Published var importing = false
    @Published var importNote: String?
    @Published var anilistUser = UserDefaults.standard.string(forKey: "anilistUser") ?? "" { didSet { UserDefaults.standard.set(anilistUser, forKey: "anilistUser") } }

    func merge(_ items: [Import.Item]) -> Int {
        var l = list, added = 0
        for i in items {
            var e = l[i.anime.id] ?? Entry(anime: i.anime)
            if e.status == nil && e.favourite == false { added += 1 }
            if e.status == nil { e.status = i.status }
            e.favourite = e.favourite || i.favourite
            l[i.anime.id] = e
        }
        list = l // one save
        return added
    }

    func runImport(_ source: String, _ work: () async throws -> ([Import.Item], Int)) async {
        importing = true; importNote = nil
        defer { importing = false }
        do {
            let (items, missing) = try await work()
            let added = merge(items)
            importNote = items.isEmpty ? "Nothing to import from \(source)." :
                "Imported \(items.count) shows from \(source): \(added) new, \(items.count - added) already on My list." +
                (missing > 0 ? " \(missing) couldn't be found on AniList." : "")
            if items.contains(where: { $0.status == .watching || $0.status == .planning }) { Alerts.ask() }
        } catch {
            importNote = "Couldn't import from \(source). " + (source == "AniList" ? "Check the user name, and that the list is public." : "Check it's the file MyAnimeList exported.")
        }
    }

    func importAniList() async {
        let u = anilistUser.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        await runImport("AniList") { (try await Import.anilist(user: u), 0) }
    }

    func importMAL() async {
        guard let f = Import.pickMALFile() else { return }
        await runImport("MyAnimeList") { try await Import.mal(file: f) }
    }

    func put(_ id: String, _ e: Entry) { list[id] = e.status == nil && !e.favourite ? nil : e }

    func open(_ id: String) {
        guard let e = list[id] else { return }
        tab = .list
        path = [e.anime]
    }

    // MARK: Schedule

    func loadSchedule(force: Bool = false) async {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let day = ISO8601DateFormatter.string(from: start, timeZone: .current, formatOptions: [.withFullDate])
        guard schedule == nil || force || day != scheduleDay else { return } // a new day: reload
        scheduleDay = day
        schedule = await fetch("schedule:" + day, [{ try await AniList.schedule(from: start, to: end) }]) ?? []
    }

    // MARK: New-episode alerts

    // Shows to alert on: on the list, not finished, from AniList (Kitsu has no airing times).
    static func alertIds(_ list: [String: Entry]) -> [Int] {
        list.filter { $0.value.status != .finished && ($0.value.status != nil || $0.value.favourite) }
            .compactMap { $0.key.hasPrefix("anilist:") ? Int($0.key.dropFirst("anilist:".count)) : nil }.sorted()
    }

    func checkAiring(now: Date = Date()) async {
        let ids = Self.alertIds(list)
        let last = UserDefaults.standard.object(forKey: "lastAiringCheck") as? Date
        guard !ids.isEmpty else { UserDefaults.standard.set(now, forKey: "lastAiringCheck"); return }
        if alertsOn { Alerts.ask() } // no-op once you've answered macOS's prompt
        // First check ever: look back only an hour, so adding a show doesn't dump old episodes on you.
        let from = max(last ?? now.addingTimeInterval(-3600), now.addingTimeInterval(-7 * 86400))
        guard let r = try? await AniList.airing(ids: ids, from: from, to: now) else { return } // retry next time, same window
        UserDefaults.standard.set(now, forKey: "lastAiringCheck")
        for (id, next) in r.next {
            guard var e = list["anilist:\(id)"] else { continue }
            e.anime.nextEpisode = next?.0
            e.anime.nextAiring = next?.1
            list["anilist:\(id)"] = e
        }
        guard alertsOn else { return }
        for a in r.aired {
            guard let e = list["anilist:\(a.id)"] else { continue }
            Alerts.post(title: e.anime.title, body: "Episode \(a.episode) is out", id: "anilist:\(a.id)")
        }
    }
}

struct Slide: Identifiable { let anime: Anime; let note: String; var id: String { anime.id } }
