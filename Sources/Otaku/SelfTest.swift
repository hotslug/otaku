import Foundation

// OTAKU_SELFTEST=1 .build/debug/Otaku  — offline checks of the parsing/matching logic.
@MainActor enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL (SelfTest.swift:\(line)): \(what)") }
    }

    // OTAKU_LIVE=1 also hits the real APIs.
    static func live() {
        var done = false
        Task {
            var step = ""
            do {
                step = "AniList.home()"
                let h = try await AniList.home()
                check(h.rows.count == 10 && h.rows.allSatisfy { $0.items.count == 20 }, "anilist home: all 10 rows full")
                for row in h.rows { print("AniList \(row.title):", row.items.prefix(3).map(\.title)) }
                step = "Kitsu.home()"
                let k = try await Kitsu.home()
                check(k.rows.count == 2 && k.rows.allSatisfy { !$0.items.isEmpty }, "kitsu home")
                print("Kitsu:", k.rows.map { "\($0.title): \($0.items.prefix(3).map(\.title))" })
                step = "AniList.search('frieren')"
                let r = try await AniList.search("frieren")
                check(r.first?.title.contains("Frieren") == true, "anilist search")
                step = "search demon slayer"
                let ds = try await AniList.search("demon slayer")
                check(ds.first?.title.contains("Kimetsu") == true, "popular match first: \(ds.prefix(2).map(\.title))")
                let f = Filters(genre: "Romance", year: 2024, format: "TV", status: "FINISHED", sort: "SCORE_DESC")
                step = "AniList.search('', f)"
                let fr = try await AniList.search("", f)
                check(!fr.isEmpty && fr.allSatisfy { $0.year == "2024" && $0.format == "TV" && $0.status == "Finished" }, "anilist filters: \(fr.prefix(3).map { "\($0.title) \($0.year ?? "") \($0.format ?? "")" })")
                check(zip(fr, fr.dropFirst()).allSatisfy { ($0.score ?? 0) >= ($1.score ?? 0) }, "best rated first")
                print("Romance 2024 TV finished, best rated:", fr.prefix(3).map { "\($0.title) ★\($0.score ?? 0)" })
                step = "AniList.search('gundam', Filters(format: 'MOV"
                let qf = try await AniList.search("gundam", Filters(format: "MOVIE"))
                check(!qf.isEmpty && qf.allSatisfy { $0.format == "Movie" }, "search + format filter")
                step = "Kitsu.search('', Filters(year: 2024, format: "
                // Kitsu counts late-December starts in the next season, so 2023 is fine here.
                let kf = try await Kitsu.search("", Filters(year: 2024, format: "MOVIE"))
                check(!kf.isEmpty && kf.allSatisfy { $0.format == "Movie" && ["2023", "2024"].contains($0.year ?? "") }, "kitsu filters: \(kf.prefix(3).map { "\($0.title) \($0.year ?? "") \($0.format ?? "")" })")
                step = "Kitsu.search('frieren')"
                let ks = try await Kitsu.search("frieren")
                check(!ks.isEmpty, "kitsu search")
                step = "AniList.detail('anilist:16498')"
                let d = try await AniList.detail("anilist:16498")
                print("AoT related:", d.related?.prefix(6).map { "\($0.relation): \($0.anime.title)" } ?? [])
                check(d.related?.contains { $0.relation == "Sequel" && $0.anime.title.contains("Season 2") } == true, "AoT sequel is Season 2")
                print("AoT recommended:", d.recommended?.prefix(5).map(\.title) ?? [])
                check((d.recommended?.count ?? 0) >= 5, "AoT has recommendations")
                print("AoT cast:", d.cast?.prefix(3).map { "\($0.name) (\($0.role)) JP \($0.japanese?.name ?? "-") / EN \($0.english?.name ?? "-")" } ?? [])
                check(d.cast?.first?.role == "Main" && d.cast?.first?.japanese != nil, "AoT cast: main characters first, with voices")
                print("AoT trailer:", d.trailer?.page?.absoluteString ?? "none")
                check(d.trailer?.embed != nil, "AoT has a trailer")
                check(d.tvSeasons ?? 0 >= 5, "AoT season chain with related + recs in the same request: \(d.tvSeasons ?? -1)")
                print("AoT seasons:", d.tvSeasons ?? -1, d.seasonsMore, "links:", d.links.map(\.site), "synopsis:", d.synopsis.prefix(80))
                step = "Kitsu.detail(title: 'Frieren')"
                let kd = try await Kitsu.detail(title: "Frieren")
                print("Kitsu fallback detail:", kd.title, kd.links.map(\.site))
                check(!kd.links.isEmpty, "kitsu links")
                let now = Date()
                step = "AniList.schedule(from: now, to: now.addingTim"
                let week = try await AniList.schedule(from: now, to: now.addingTimeInterval(7 * 86400))
                check(week.count > 50, "schedule has a week of episodes: \(week.count)")
                print("Schedule:", week.count, "episodes; first:", week.first.map { "\($0.anime.title) ep \($0.episode) at \($0.at)" } ?? "-")
                let ids = Array(Set(week.prefix(20).compactMap { Int($0.anime.id.dropFirst(8)) })).sorted()
                step = "AniList.airing(ids: ids, from: now.addingTime"
                let air = try await AniList.airing(ids: ids, from: now.addingTimeInterval(-7 * 86400), to: now)
                print("Aired last week for 20 shows:", air.aired.count, "next known:", air.next.values.compactMap { $0 }.count)
                check(!air.next.isEmpty, "airing check returns next episodes")
            } catch { check(false, "live (\(step)): \(error)") }
            done = true
        }
        let end = Date() + 40
        while !done, Date() < end { RunLoop.main.run(until: Date() + 0.05) }
    }

    static func run() -> Int32 {
        check(plain("A<br>\nB <i>c</i> &quot;d&quot; &amp; e") == "A\n\nB c \"d\" & e", "html stripped: \(plain("A<br>\nB <i>c</i> &quot;d&quot; &amp; e"))")

        // S1(TV) -> movie -> S2(TV) -> S3(TV, 3 hops away: the chain may go on)
        func node(_ id: Int, _ f: String, _ edges: [(String, J)] = []) -> J {
            ["id": id, "format": f, "relations": ["edges": edges.map { ["relationType": $0.0, "node": $0.1] }]]
        }
        let s4: J = ["id": 4, "format": "TV"] // beyond the query depth: no relations field
        let root = node(1, "TV", [("SEQUEL", node(10, "MOVIE", [("SEQUEL", node(2, "TV", [("SEQUEL", s4)]))])), ("SIDE_STORY", node(99, "TV"))])
        var c = AniList.Chain()
        c.add([root])
        check(c.tv.count == 3 && c.frontier == [4], "seasons through a movie, ignores side stories: \(c.tv) \(c.frontier)")
        c.frontier = []
        c.add([node(4, "TV", [("PREQUEL", node(2, "TV")), ("SEQUEL", node(5, "TV", []))])]) // follow-up request
        check(c.tv.count == 4 && c.frontier == [5], "follow-up adds S5 once, revisits nothing, S5's empty list gets loaded: \(c.tv) \(c.frontier)")
        c.frontier = []
        c.add([node(5, "TV", [])]) // loaded as a top-level node: really has nothing more
        check(c.tv.count == 4 && c.frontier.isEmpty, "chain ends when a loaded show has no sequels")
        var c1 = AniList.Chain()
        c1.add([node(1, "TV", [("ADAPTATION", node(5, "MANGA"))])])
        check(c1.tv.count == 1 && c1.frontier.isEmpty, "single season")

        let terms = TMDB.searchTerms(["Attack on Titan Season 3 Part 2", "Shingeki no Kyojin Season 3 Part 2"])
        check(terms.contains("Attack on Titan") && terms.first == "Attack on Titan Season 3 Part 2", "search terms: \(terms)")
        check(TMDB.searchTerms(["Demon Slayer: Kimetsu no Yaiba"]).contains("Demon Slayer"), "colon stripped")

        let ranked = TMDB.rank([["id": 1, "name": "Live action", "genre_ids": [18]], ["id": 2, "name": "Anime", "genre_ids": [16], "original_language": "ja", "first_air_date": "2013-04-07"]])
        check(ranked.first?.id == 2 && ranked.first?.year == "2013", "animated Japanese first: \(ranked)")

        let links = [StreamLink(site: "Crunchyroll", url: URL(string: "https://cr.com/x")!), StreamLink(site: "Netflix", url: URL(string: "https://nf.com/x")!)]
        check(directLink("Netflix basic with Ads", links)?.host == "nf.com", "netflix variant matched")
        check(directLink("Hulu", links) == nil, "no false match")

        // My list: which shows get alerts, and a damaged list file is kept aside, not lost.
        func entry(_ id: String, _ st: Status?, fav: Bool = false) -> Entry {
            Entry(anime: Anime(id: id, title: id, synopsis: "", genres: [], links: [], titles: []), status: st, favourite: fav)
        }
        let l = ["anilist:1": entry("anilist:1", .watching), "anilist:2": entry("anilist:2", .finished), "anilist:3": entry("anilist:3", nil, fav: true),
                 "kitsu:4": entry("kitsu:4", .watching), "anilist:5": entry("anilist:5", .planning)]
        check(Store.alertIds(l) == [1, 3, 5], "alert ids: \(Store.alertIds(l))")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otaku-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("list.json")
        try? JSONEncoder().encode(l).write(to: f)
        check(Store.loadList(from: f).count == 5, "list round trip")
        try? Data("not json".utf8).write(to: f)
        check(Store.loadList(from: f).isEmpty && !FileManager.default.fileExists(atPath: f.path), "broken list moved aside")
        check((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasPrefix("list.json.broken-") } == true, "broken copy kept")
        try? FileManager.default.removeItem(at: dir)

        check(AniList.season(DateComponents(calendar: .current, year: 2026, month: 11, day: 23).date!) == ("FALL", 2026)
              && AniList.season(DateComponents(calendar: .current, year: 2027, month: 1, day: 5).date!) == ("WINTER", 2027), "seasons by month")
        let rel = AniList.related([
            ["relationType": "ADAPTATION", "node": ["id": 1, "type": "MANGA", "title": ["romaji": "Manga"]]],
            ["relationType": "SIDE_STORY", "node": ["id": 2, "type": "ANIME", "format": "OVA", "title": ["romaji": "OVA"]]],
            ["relationType": "SEQUEL", "node": ["id": 3, "type": "ANIME", "format": "TV", "title": ["romaji": "S2"]]],
            ["relationType": "PREQUEL", "node": ["id": 4, "type": "ANIME", "format": "TV", "title": ["romaji": "S0"]]],
            ["relationType": "ALTERNATIVE", "node": ["id": 5, "type": "ANIME", "format": "MOVIE", "title": ["romaji": "Film"]]],
        ])
        check(rel.map(\.relation) == ["Prequel", "Sequel", "Side story", "Movie"], "related: anime only, watch order: \(rel.map(\.relation))")
        let u = URL(string: "https://x.com")!
        let g = Buttons.group([("Hulu", u), ("Hoopla (Sub)", u), ("Hoopla (Dub)", u), ("Crunchyroll", u), ("YouTube (VIZ Media)", u)])
        check(g.map(\.name) == ["Crunchyroll", "Hulu", "Hoopla", "YouTube"] && g[2].variants.map(\.0) == ["Sub", "Dub"] && g[3].variants.map(\.0) == ["VIZ Media"],
              "links grouped, big services first: \(g.map { "\($0.name) \($0.variants.map(\.0))" })")
        // Movie of the Night: a sample show, as their docs describe it.
        let show: J = ["title": "Frieren: Beyond Journey's End", "tmdbId": "tv/209867", "firstAirYear": 2023, "seasonCount": 1,
                       "genres": [["id": "animation", "name": "Animation"]],
                       "streamingOptions": ["gb": [
                           ["service": ["id": "crunchyroll", "name": "Crunchyroll", "homePage": "https://www.crunchyroll.com/"], "type": "subscription", "link": "https://www.crunchyroll.com/series/GG5H5XQX4"],
                           ["service": ["id": "prime", "name": "Prime Video"], "type": "buy", "link": "https://www.amazon.co.uk/gp/video/detail/x"],
                           ["service": ["id": "crunchyroll", "name": "Crunchyroll"], "type": "subscription", "link": "https://www.crunchyroll.com/other"],
                       ]]]
        let mw = MotN.watch(from: show, country: "gb", candidates: [])
        check(mw.stream == ["Crunchyroll"] && mw.buy == ["Prime Video"] && mw.tmdbId == 209867 && mw.seasons == 1, "motn lists: \(mw.stream) \(mw.buy)")
        check(mw.direct["Crunchyroll"]?.absoluteString == "https://www.crunchyroll.com/series/GG5H5XQX4", "motn direct link: first one wins")
        let ranked2 = MotN.rank([["title": "Live", "firstAirYear": 2023], ["title": "Anime", "firstAirYear": 2019, "genres": [["id": "animation"]]],
                                 ["title": "Anime 2023", "firstAirYear": 2023, "genres": [["id": "animation"]]]], year: 2023)
        check(ranked2.first?.s("title") == "Anime 2023", "motn ranks animated + same year first")
        check(MotN.watch(from: show, country: "us", candidates: []).stream.isEmpty, "motn: other countries ignored")
        let sp = Synopsis.split("The adventure is over.\n\n(Source: Crunchyroll)")
        check(sp.body == "The adventure is over." && sp.source == "Crunchyroll", "synopsis source split: \(sp)")
        check(Synopsis.split("Text [Written by MAL Rewrite]").source == "MAL Rewrite", "MAL-style credit")
        check(Synopsis.split("No credit here (really).").source == nil, "no false credit")
        check(AniList.date(["year": 2013, "month": 4, "day": 7]) == "2013-04-07" && AniList.date(["year": 2026]) == "2026", "dates")

        if ProcessInfo.processInfo.environment["OTAKU_LIVE"] != nil { live() }

        print(failures == 0 ? "All checks passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
