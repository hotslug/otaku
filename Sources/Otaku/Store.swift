import Foundation

@MainActor final class Store: ObservableObject {
    static let shared = Store()

    @Published var home: Home?
    @Published var query = ""
    @Published var results: [Anime]?
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
        if home == nil { home = await fetch("home", [AniList.home, Kitsu.home]) }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        results = await fetch("search:" + q.lowercased(), [{ try await AniList.search(q) }, { try await Kitsu.search(q) }]) ?? []
        resultsFor = q
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
}
