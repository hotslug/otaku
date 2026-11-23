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
    @Published var hoverCard: String?
    @Published var expandedLinks: Set<String> = [] // link lists showing "+N more" expanded
    @Published var schedule: [Airing]?
    @Published var onlyMine = UserDefaults.standard.bool(forKey: "onlyMine") { didSet { UserDefaults.standard.set(onlyMine, forKey: "onlyMine") } }
    @Published var alertsOn = UserDefaults.standard.object(forKey: "alertsOn") as? Bool ?? true { didSet { UserDefaults.standard.set(alertsOn, forKey: "alertsOn") } }
    @Published var list: [String: Entry] = Store.loadList() { didSet { saveList() } }

    @Published var home: Home?
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
    @Published var stale = false // showing saved data because every source failed
    @Published var error: String?
    @Published var tmdbKey = UserDefaults.standard.string(forKey: "tmdbKey") ?? "" {
        didSet { UserDefaults.standard.set(tmdbKey, forKey: "tmdbKey"); watch = [:] }
    }

    var key: String { tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var region: String { Locale.current.region?.identifier ?? "US" }
    var regionName: String { Locale.current.localizedString(forRegionCode: region) ?? region }

    // Tries each source in order; saves the first answer, or falls back to the last saved one.
    func fetch<T: Codable>(_ cacheKey: String, _ sources: [() async throws -> T], main: Bool = true) async -> T? {
        let file = Cache.url(cacheKey)
        for source in sources {
            if let v = try? await source() {
                try? JSONEncoder().encode(v).write(to: file)
                if main { stale = false; error = nil }
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

    // Search as you type: waits for a short pause, so a word costs one request, not one per letter.
    var typing: Task<Void, Never>?

    func typed() {
        typing?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.isEmpty || q.count >= 2 else { return } // one letter: wait for more
        typing = Task {
            if !q.isEmpty { try? await Task.sleep(for: .milliseconds(550)) }
            guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespaces) else { return }
            if !q.isEmpty, tab != .discover || !path.isEmpty { tab = .discover; path = [] } // typing elsewhere: show the results
            if !q.isEmpty, q == resultsFor, results != nil { return } // already showing these
            await search() // empty: back to filters only, or the start page
        }
    }

    func retry() async {
        error = nil
        if results != nil { await search() } else { home = nil; await loadHome() }
    }

    func loadDetail(_ a: Anime) async {
        if details[a.id] == nil {
            let title = a.titles.first ?? a.title
            details[a.id] = await fetch("detail:" + a.id, a.id.hasPrefix("kitsu:")
                ? [{ try await Kitsu.detail(id: a.id) }]
                : [{ try await AniList.detail(a.id) }, { try await Kitsu.detail(title: title) }]) ?? a
        }
        await loadWatch(a)
    }

    func loadWatch(_ a: Anime) async {
        let key = key, region = region
        guard !key.isEmpty, watch[a.id] == nil else { return }
        let pick = UserDefaults.standard.object(forKey: "tmdb." + a.id) as? Int
        watch[a.id] = await fetch("watch:\(a.id):\(region):\(pick ?? 0)",
                                  [{ try await TMDB.watch(for: a, key: key, region: region, pick: pick) }], main: false)
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
