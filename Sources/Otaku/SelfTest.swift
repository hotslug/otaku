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
            do {
                let h = try await AniList.home()
                check(h.popular.count == 30 && h.trending.count == 30, "anilist home")
                print("AniList popular:", h.popular.prefix(5).map(\.title))
                let k = try await Kitsu.home()
                check(!k.popular.isEmpty && !k.trending.isEmpty, "kitsu home")
                print("Kitsu popular:", k.popular.prefix(5).map(\.title))
                let r = try await AniList.search("frieren")
                check(r.first?.title.contains("Frieren") == true, "anilist search")
                let ks = try await Kitsu.search("frieren")
                check(!ks.isEmpty, "kitsu search")
                let d = try await AniList.detail("anilist:16498")
                print("AoT seasons:", d.tvSeasons ?? -1, d.seasonsMore, "links:", d.links.map(\.site), "synopsis:", d.synopsis.prefix(80))
                let kd = try await Kitsu.detail(title: "Frieren")
                print("Kitsu fallback detail:", kd.title, kd.links.map(\.site))
                check(!kd.links.isEmpty, "kitsu links")
            } catch { check(false, "live: \(error)") }
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
        check(c.tv.count == 4 && c.frontier.isEmpty, "follow-up adds S5 once, revisits nothing: \(c.tv) \(c.frontier)")
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

        check(AniList.date(["year": 2013, "month": 4, "day": 7]) == "2013-04-07" && AniList.date(["year": 2026]) == "2026", "dates")

        if ProcessInfo.processInfo.environment["OTAKU_LIVE"] != nil { live() }

        print(failures == 0 ? "All checks passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
