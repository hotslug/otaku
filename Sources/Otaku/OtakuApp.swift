import AppKit
import SwiftUI

@main
struct OtakuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup { ContentView(store: .shared).frame(minWidth: 720, minHeight: 520) }
        Settings { SettingsView(store: .shared) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["OTAKU_ICON"] { exit(Icon.write(to: out) ? 0 : 1) }
        if env["OTAKU_SELFTEST"] != nil { exit(SelfTest.run()) }
        NSApp.setActivationPolicy(.regular) // `swift run` has no bundle; make it a normal app
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var store: Store

    var body: some View {
        NavigationStack(path: $store.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.stale {
                        Label("Showing saved data: AniList and Kitsu can't be reached right now.", systemImage: "wifi.slash")
                            .foregroundStyle(.orange)
                    }
                    if let e = store.error {
                        HStack { Text(e); Button("Retry") { Task { await store.retry() } } }
                    }
                    if let r = store.results {
                        if r.isEmpty { Text("No anime found for “\(store.resultsFor)”.").foregroundStyle(.secondary) }
                        else { Shelf(title: "Results for “\(store.resultsFor)”", items: r) }
                    } else if let h = store.home {
                        Shelf(title: "Most popular", items: h.popular)
                        Shelf(title: "Trending now", items: h.trending)
                    } else if store.error == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Otaku")
            .navigationDestination(for: Anime.self) { DetailView(store: store, anime: $0) }
            .searchable(text: $store.query, placement: .toolbar, prompt: "Search anime")
            .onSubmit(of: .search) { store.path = []; Task { await store.search() } }
        }
        .onChange(of: store.query) { if store.query.isEmpty { store.results = nil } }
        .task {
            await store.loadHome()
            // Layout checks: OTAKU_QUERY=frieren (+ OTAKU_OPEN=1 to open the first result).
            let env = ProcessInfo.processInfo.environment
            if let q = env["OTAKU_QUERY"] {
                store.query = q
                await store.search()
                if env["OTAKU_OPEN"] != nil, let first = store.results?.first { store.path = [first] }
            }
        }
    }
}

struct Shelf: View {
    let title: String
    let items: [Anime]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                ForEach(items) { a in
                    NavigationLink(value: a) { Card(a: a) }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct Card: View {
    let a: Anime

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Poster(url: a.poster, width: 140, height: 200)
            Text(a.title).font(.headline).lineLimit(2)
            Text([a.score.map { "★ \($0)" }, a.year, a.format].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 140, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct Poster: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
            Color.secondary.opacity(0.15).overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DetailView: View {
    @ObservedObject var store: Store
    let anime: Anime

    var body: some View {
        let a = store.details[anime.id] ?? anime
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let b = a.banner {
                    AsyncImage(url: b) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
                        .frame(height: 160).frame(maxWidth: .infinity).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack(alignment: .top, spacing: 22) {
                    Poster(url: a.poster, width: 200, height: 290)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(a.title).font(.largeTitle.bold()).textSelection(.enabled)
                        if let n = a.native { Text(n).font(.title3).foregroundStyle(.secondary).textSelection(.enabled) }
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                            row("Started", a.start)
                            row("Ended", a.end)
                            row("Status", a.status)
                            row("Format", a.format)
                            row("Seasons", seasons(a))
                            row("Episodes", a.episodes.map(String.init))
                            row("Score", a.score.map { "\($0) / 100" })
                            row("Fans", a.popularity?.formatted())
                            row("Studio", a.studio)
                            row("Genres", a.genres.isEmpty ? nil : a.genres.joined(separator: ", "))
                        }
                    }
                }
                if !a.synopsis.isEmpty {
                    Text(a.synopsis).textSelection(.enabled).frame(maxWidth: 760, alignment: .leading)
                }
                whereToWatch(a)
            }
            .padding(24)
        }
        .navigationTitle(a.title)
        .task { await store.loadDetail(anime) }
    }

    func seasons(_ a: Anime) -> String? {
        if let s = store.watch[anime.id]?.seasons { return "\(s)" }
        guard let n = a.tvSeasons, n > 0 else { return nil }
        return (a.seasonsMore ? "\(n)+" : "\(n)") + " TV parts"
    }

    @ViewBuilder func row(_ k: String, _ v: String?) -> some View {
        if let v { GridRow { Text(k).foregroundStyle(.secondary); Text(v).textSelection(.enabled) } }
    }

    @ViewBuilder func whereToWatch(_ a: Anime) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where to watch").font(.title2.bold())
            if store.key.isEmpty {
                Text("Add a free TMDB key in Settings (⌘,) to see what's available in \(store.regionName) and where it first aired.")
                    .foregroundStyle(.secondary)
            } else if let w = store.watch[anime.id] {
                if w.tmdbId == nil {
                    Text("Couldn't match this show on TMDB.").foregroundStyle(.secondary)
                } else {
                    if !w.stream.isEmpty {
                        Text("Streaming in \(store.regionName)").font(.headline)
                        Buttons(items: w.stream.compactMap { p in (directLink(p, a.links) ?? w.link).map { (p, $0) } })
                    }
                    if !w.buy.isEmpty {
                        Text("Rent or buy in \(store.regionName)").font(.headline)
                        Buttons(items: w.buy.compactMap { p in (directLink(p, a.links) ?? w.link).map { (p, $0) } })
                    }
                    if w.stream.isEmpty, w.buy.isEmpty {
                        Text("Not available in \(store.regionName) right now.").foregroundStyle(.secondary)
                    }
                    if !w.networks.isEmpty {
                        Text("Originally aired on: " + w.networks.joined(separator: ", "))
                    }
                    Text("Availability from JustWatch via TMDB · matched “\(w.name)”\(w.year.map { " (\($0))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !w.candidates.isEmpty {
                    Menu("Wrong match?") {
                        ForEach(w.candidates) { c in
                            Button(c.name + (c.year.map { " (\($0))" } ?? "")) { store.choose(anime, c.id) }
                        }
                        Divider()
                        Button("None of these") { store.choose(anime, -1) }
                    }
                    .fixedSize()
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if !a.links.isEmpty {
                Text("All streaming links").font(.headline).padding(.top, 6)
                Text("Worldwide list: not every service carries it in every country.").font(.caption).foregroundStyle(.secondary)
                Buttons(items: a.links.map { ($0.site + ($0.note.map { " (\($0))" } ?? ""), $0.url) })
            }
        }
    }
}

struct Buttons: View {
    let items: [(String, URL)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Link(destination: item.1) { Text(item.0).lineLimit(1).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        Form {
            SecureField("TMDB key", text: $store.tmdbKey)
            Text("Optional. Shows what's streaming in \(store.regionName) (from your Mac's region) and where a show first aired. The API key or the read access token both work.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Get a free key at themoviedb.org", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
        }
        .padding(20)
        .frame(width: 460)
    }
}
