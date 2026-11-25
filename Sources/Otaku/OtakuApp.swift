import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import WebKit

@main
struct OtakuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(store: .shared).frame(minWidth: 720, minHeight: 520)
                .tint(Theme.pink)
        }
        .restorationBehavior(.disabled) // always open a window on launch (it stays running with none, for alerts)
        .defaultSize(width: 1240, height: 860)
        Settings { SettingsView(store: .shared).tint(Theme.pink) }
        MenuBarExtra(isInserted: Binding(get: { Store.shared.inMenuBar }, set: { Store.shared.inMenuBar = $0 })) {
            MenuBarPanel(store: .shared).tint(Theme.pink)
        } label: {
            MenuBarLabel(store: .shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["OTAKU_ICON"] { exit(Icon.write(to: out) ? 0 : 1) }
        if let dir = env["OTAKU_DMG_BG"] { exit(Icon.writeDMGBackground(to: dir) ? 0 : 1) } // release.sh: DMG window picture
        if let out = env["OTAKU_MENU_ICON"] { // preview of the menu bar icon, 8x size, white on dark and black on light
            let img = NSImage(size: NSSize(width: 320, height: 160), flipped: false) { _ in
                NSColor(white: 0.15, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 160, height: 160).fill()
                NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 160, y: 0, width: 160, height: 160).fill()
                for (x, c) in [(8.0, NSColor.white), (168, NSColor.black)] {
                    let tinted = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                        MenuBarLabel.icon.draw(in: r); c.set(); r.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: x, y: 8, width: 144, height: 144))
                }
                return true
            }
            let png = img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            exit((try? png?.write(to: URL(fileURLWithPath: out))) != nil ? 0 : 1)
        }
        if env["OTAKU_SELFTEST"] != nil { exit(SelfTest.run()) }
        NSApp.setActivationPolicy(.regular) // `swift run` has no bundle; make it a normal app
        if Alerts.available { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Keys.install()
        Store.shared.appearance.apply()

        // Keeps running with the window closed (click the Dock icon to reopen) so alerts still arrive.
        Task { @MainActor in
            while true {
                await Store.shared.checkAiring()
                await Store.shared.loadSchedule() // once a day; feeds the menu bar
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let id = r.notification.request.content.userInfo["anime"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            if NSApp.windows.allSatisfy({ !$0.isVisible }) { NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil) }
            Store.shared.open(id)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationStack(path: $store.path) {
            Group {
                switch store.tab {
                case .discover: DiscoverView(store: store)
                case .list: MyListView(store: store)
                case .schedule: ScheduleView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.sky.ignoresSafeArea())
            .toolbarBackground(Theme.dusk, for: .windowToolbar) // match the night sky below
            .toolbarBackgroundVisibility(store.heroOnTop ? .hidden : .visible, for: .windowToolbar) // a page's hero picture runs up under it
            .navigationTitle("Otaku")
            .navigationDestination(for: Anime.self) { a in
                DetailView(store: store, anime: a)
                    .navigationBarBackButtonHidden() // our own back, so the torii can sit before it
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            HStack(spacing: 2) {
                                if store.path.count > 1 { // deep in related shows: one click back to where we started
                                    Button { store.path = [] } label: { Image(nsImage: MenuBarLabel.torii) }
                                        .help("Back to \(store.tab.rawValue)")
                                }
                                Button { store.path.removeLast() } label: { Image(systemName: "chevron.left") }
                                    .help("Back")
                                    .keyboardShortcut("[", modifiers: .command)
                            }
                        }
                    }
            }
            .searchable(text: $store.query, placement: .toolbar, prompt: "Search anime  (⌘F)")
            .onSubmit(of: .search) { store.typing?.cancel(); store.path = []; store.tab = .discover; Task { await store.search() } }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        ForEach(Tab.allCases, id: \.self) { t in
                            Button { store.tab = t; store.path = [] } label: { Label(t.rawValue, systemImage: t.icon) }
                                .buttonStyle(ChipStyle(active: store.tab == t))
                                .labelStyle(.titleAndIcon) // toolbars show icons only by default
                                .focusable(false)
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .onChange(of: store.query) { store.typed() }
        .alert(store.confirmRemove.map { "Remove “\($0.title)” from My list?" } ?? "",
               isPresented: Binding(get: { store.confirmRemove != nil }, set: { if !$0 { store.confirmRemove = nil } }),
               presenting: store.confirmRemove) { a in
            Button("Remove", role: .destructive) { store.setStatus(a, nil); store.confirmRemove = nil }
            Button("Cancel", role: .cancel) { store.confirmRemove = nil }
        } message: { a in
            let e = store.list[a.id]
            Text([e?.status.map { "It's in \($0.rawValue)." },
                  e?.status != .finished ? "You'll stop getting new-episode alerts for it." : nil,
                  e?.favourite == true ? "It stays in your Favourites." : nil].compactMap { $0 }.joined(separator: " "))
        }
        .task {
            await store.loadHome()
            NSApp.windows.forEach(Keys.styleSearch) // also when the window never becomes key (launched from a script); the toolbar is up by now
            // Layout checks: OTAKU_QUERY=frieren (+ OTAKU_OPEN=1 to open the first result), OTAKU_TAB=Schedule, OTAKU_HOVER=<row title>, OTAKU_SETTINGS=1.
            let env = ProcessInfo.processInfo.environment
            if let t = env["OTAKU_TAB"].flatMap(Tab.init(rawValue:)) { store.tab = t }
            if let s = env["OTAKU_SEASON"] { store.filters.season = "WINTER"; store.filters.year = Int(s) } // e.g. OTAKU_SEASON=2027
            if env["OTAKU_SURPRISE"] != nil { try? await Task.sleep(for: .seconds(4)); await store.surprise() } // after any filters have loaded, like a click
            if env["OTAKU_SETTINGS"] != nil { openSettings() }
            if let out = env["OTAKU_MENU_SNAPSHOT"] { // layout check: draw the menu bar panel to a PNG
                await store.loadSchedule()
                let r = ImageRenderer(content: MenuBarPanel(store: store).environment(\.colorScheme, .dark))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation { try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
            }
            if let word = env["OTAKU_TYPE"] { // types a word letter by letter, like a person
                for i in 1...word.count {
                    store.query = String(word.prefix(i))
                    try? await Task.sleep(for: .milliseconds(140))
                }
            }
            if let row = env["OTAKU_HOVER"], let items = store.home?.rows.first(where: { $0.title == row })?.items, items.count > 7 {
                store.hoverRow = row // pretend the pointer is on this row, paged once
                var p = ScrollPosition()
                p.scrollTo(x: 3 * Strip.step)
                store.rowScroll[row] = p
                store.hoverCard = row + "|" + items[4].id
            }
            if let q = env["OTAKU_QUERY"] {
                store.query = q
                await store.search()
                if env["OTAKU_OPEN"] != nil, let first = store.results?.first {
                    store.path = env["OTAKU_OPEN"] == "2" ? Array(store.results!.prefix(2)) : [first] // 2 = drilled down, shows the torii
                    if env["OTAKU_PLAY"] != nil { // also open its trailer once the page has loaded
                        try? await Task.sleep(for: .seconds(4))
                        store.playing = store.details[first.id]?.trailer
                    }
                }
            }
        }
    }
}

struct Banners: View {
    @ObservedObject var store: Store

    var body: some View {
        if store.stale {
            Label("Showing saved data: AniList and Kitsu can't be reached right now.", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        } else if store.fallback {
            HStack(spacing: 10) {
                Label("AniList isn't answering right now, so this is from Kitsu. Some rows, trailers and recommendations may be missing.", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                Button { Task { await store.retry() } } label: { Label("Try AniList again", systemImage: "arrow.clockwise") }
                    .buttonStyle(ChipStyle())
                    .focusable(false)
                    .help("Reload from AniList")
            }
        }
        if let e = store.error {
            HStack {
                Text(e)
                Button { Task { await store.retry() } } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(ChipStyle())
            }
        }
    }
}

struct DiscoverView: View {
    @ObservedObject var store: Store

    var body: some View {
        let slides = store.heroOnTop ? store.discoverSlides : []
        ScrollViewReader { proxy in
        ScrollView {
            if !slides.isEmpty { Carousel(store: store, slides: slides).transition(.opacity) }
            VStack(alignment: .leading, spacing: 28) {
                Banners(store: store)
                FilterBar(store: store)
                if store.searching {
                    SkeletonGrid().transition(.identity) // placeholders vanish at once; only real content fades in
                } else if let r = store.results {
                    let what = store.resultsFor.isEmpty ? "these filters" : "“\(store.resultsFor)”"
                    if r.isEmpty { Text("No anime found for \(what).").foregroundStyle(.secondary) }
                    else if r.count > 1 { Shelf(store: store, title: store.resultsTitle, items: Array(r.dropFirst())) } // the first is the picture above
                } else if store.home != nil {
                    ForEach(store.discoverRows) { Strip(store: store, title: $0.title, items: $0.items) }
                } else if store.error == nil {
                    ForEach(0..<3, id: \.self) { _ in SkeletonStrip().transition(.identity) }
                }
            }
            .padding(24)
            .animation(.easeOut(duration: 0.3), value: store.searching)
            .animation(.easeOut(duration: 0.4), value: store.home == nil)
        }
        .heroPage(!slides.isEmpty) // the picture runs up under the toolbar like a show's page
        .onChange(of: store.reveal) { if let r = store.reveal { withAnimation { proxy.scrollTo(r) } } }
        }
        .task(id: store.list.values.filter(\.favourite).map(\.anime.id).sorted()) { await store.loadForYou() }
        .task(id: Store.newEpisodes(store.list).map(\.id)) { await store.loadNewForYou() }
    }
}

struct FilterBar: View {
    @ObservedObject var store: Store

    var body: some View {
        let f = store.filters
        HStack(spacing: 8) {
            FilterChip(icon: "theatermasks", label: f.genre ?? "Genre", active: f.genre != nil, tip: "Genre") {
                Picker("Genre", selection: $store.filters.genre) {
                    Text("Any genre").tag(String?.none)
                    Divider()
                    ForEach(Filters.genres, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            if f.season == nil { // a season already says the year
                FilterChip(icon: "calendar", label: f.year.map(String.init) ?? "Year", active: f.year != nil, tip: "Year it started") {
                    Picker("Year", selection: $store.filters.year) {
                        Text("Any year").tag(Int?.none)
                        Divider()
                        ForEach((1960...Calendar.current.component(.year, from: Date()) + 1).reversed(), id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                    }
                }
            }
            SeasonPicker(store: store)
            FilterChip(icon: "tv", label: Filters.formats.first { $0.0 == f.format }?.1 ?? "Format", active: f.format != nil, tip: "TV, movie, OVA…") {
                Picker("Format", selection: $store.filters.format) {
                    Text("Any format").tag(String?.none)
                    Divider()
                    ForEach(Filters.formats, id: \.0) { Text($0.1).tag(String?.some($0.0)) }
                }
            }
            FilterChip(icon: "dot.radiowaves.left.and.right", label: Filters.statuses.first { $0.0 == f.status }?.1 ?? "Status", active: f.status != nil,
                       tip: "Airing, finished or coming soon") {
                Picker("Status", selection: $store.filters.status) {
                    Text("Any status").tag(String?.none)
                    Divider()
                    ForEach(Filters.statuses, id: \.0) { Text($0.1).tag(String?.some($0.0)) }
                }
            }
            FilterChip(icon: "arrow.up.arrow.down", label: Filters.sorts.first { $0.0 == f.sort }?.1 ?? "Sort", active: f.sort != Filters().sort, tip: "Sort by") {
                Picker("Sort", selection: $store.filters.sort) {
                    ForEach(Filters.sorts, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            if f.active {
                Button { store.filters = Filters() } label: {
                    Label("Clear", systemImage: "xmark").chip(active: false)
                }
                .buttonStyle(.plain)
                .help("Clear all filters")
            }
            Spacer()
            Button { Task { await store.surprise() } } label: {
                Label("Surprise me", systemImage: store.surprising ? "hourglass" : "dice").chip(active: false)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(store.surprising)
            .help(f.active ? "Open a random, well-rated show that fits these filters" : "Open a random, well-rated show")
        }
        .animation(.easeOut(duration: 0.15), value: f)
    }
}

// Everything from one season, e.g. Winter 2027, with ‹ › to step to the one before or after.
struct SeasonPicker: View {
    @ObservedObject var store: Store

    var body: some View {
        let tag = store.filters.seasonTag
        HStack(spacing: 4) {
            if let tag { step(tag, -1, "chevron.left", "Season before") }
            FilterChip(icon: Filters.icon(store.filters.season), label: tag.map(Filters.label) ?? "Season", active: tag != nil,
                       tip: "Everything from one season", sizedFor: ["Season", "Summer 2026"]) {
                Picker("Season", selection: Binding(get: { tag }, set: set)) {
                    Text("Any season").tag(String?.none)
                    Divider()
                    ForEach(Filters.recentSeasons(), id: \.self) { Text(Filters.label($0)).tag(String?.some($0)) }
                }
            }
            if let tag { step(tag, 1, "chevron.right", "Season after") }
        }
    }

    func set(_ tag: String?) {
        let p = tag?.split(separator: " ")
        store.filters.season = p.map { String($0[0]) }
        store.filters.year = p.flatMap { Int($0[1]) }
    }

    func step(_ tag: String, _ n: Int, _ icon: String, _ tip: String) -> some View {
        Button { set(Filters.shift(tag, by: n)) } label: {
            Image(systemName: icon).font(.caption.weight(.bold)).frame(width: 12).chip(active: false)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(tip)
    }
}

// A pill that opens a menu: grey with its name when unset, filled with its value when set.
struct FilterChip<Content: View>: View {
    let icon: String
    let label: String
    let active: Bool
    let tip: String
    var sizedFor: [String] = [] // always as wide as the widest of these, so the pill never changes size
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content().pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                ZStack(alignment: .leading) { // label hugs its icon; the spare width goes after it
                    ForEach(sizedFor, id: \.self) { Text($0).hidden() }
                    Text(label)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).opacity(0.6)
            }
            .chip(active: active)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled() // no blue focus ring around the pill
        .fixedSize()
        .help(tip)
    }
}

extension View {
    func chip(active: Bool) -> some View {
        font(.callout.weight(.medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? AnyShapeStyle(Theme.sunset) : AnyShapeStyle(Theme.surface), in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Color.white.opacity(0.3) : Theme.edge))
            .shadow(color: active ? Theme.pink.opacity(0.35) : .clear, radius: 8, y: 2)
            .contentShape(Capsule())
    }
}

struct MyListView: View {
    @ObservedObject var store: Store

    var body: some View {
        let slides = store.heroOnTop ? store.listSlides : []
        ScrollViewReader { proxy in
        ScrollView {
            if !slides.isEmpty { Carousel(store: store, slides: slides).transition(.opacity) }
            VStack(alignment: .leading, spacing: 28) {
                if store.list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.star").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Your list is empty").font(.title2.bold())
                        Text("Open any anime and use Add to My list or the ☆ star. Shows you're watching get an alert when a new episode is out.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                }
                ForEach(store.myListRows) { row in
                    if row.title == Status.watching.rawValue { WideRow(store: store, title: row.title, items: row.items.map(store.art), notes: notes) }
                    else { Strip(store: store, title: row.title, items: row.items, notes: notes) }
                }
            }
            .padding(24)
        }
        .heroPage(!slides.isEmpty)
        .animation(.easeOut(duration: 0.3), value: slides.isEmpty)
        .onChange(of: store.reveal) { if let r = store.reveal { withAnimation { proxy.scrollTo(r) } } }
        }
        .task(id: store.list.keys.sorted()) { await store.loadListArt() }
    }

    func notes(_ a: Anime) -> String? {
        if let n = Store.newEpisodes(store.list).first(where: { $0.id == a.id }) { return "Episode \(n.episode) is out" }
        guard let ep = a.nextEpisode, let at = a.nextAiring, at > Date() else { return nil }
        return "Ep \(ep) · " + at.formatted(.relative(presentation: .named))
    }
}

struct ScheduleView: View {
    @ObservedObject var store: Store

    var body: some View {
        let mine = Set(store.list.keys)
        let items = (store.schedule ?? []).filter { !store.onlyMine || mine.contains($0.anime.id) }
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.at) }
        let hero = store.heroOnTop ? store.upNext : nil
        ScrollView {
            if let n = hero {
                TimelineView(.everyMinute) { t in // the countdown ticks
                    let mine = store.list[n.anime.id] != nil
                    Carousel(store: store, slides: [Slide(anime: n.anime, note: (mine ? "Up next from My list" : "Up next") + " · episode \(n.episode) " + Self.countdown(n.at, now: t.date))])
                }
                .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 24) {
                Banners(store: store)
                HStack {
                    SectionTitle("Airing this week")
                    Spacer()
                    Button { store.onlyMine.toggle() } label: { Label("Only My list", systemImage: store.onlyMine ? "checkmark" : "list.star") }
                        .buttonStyle(ChipStyle(active: store.onlyMine))
                        .help(store.onlyMine ? "Showing only shows on My list" : "Show only shows on My list")
                }
                if store.schedule == nil, store.error == nil { SkeletonRows() }
                if store.schedule != nil, items.isEmpty {
                    Text(store.onlyMine ? "Nothing from your list airs this week." : "Nothing scheduled.").foregroundStyle(.secondary)
                }
                TimelineView(.everyMinute) { t in
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(days.keys.sorted(), id: \.self) { day in
                            let all = days[day]!.sorted { $0.at < $1.at }
                            let aired = all.filter { $0.at <= t.date }, next = all.filter { $0.at > t.date }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInTomorrow(day) ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide).day().month()))
                                    .font(.title3.bold())
                                grid(aired).opacity(0.45).help("Already aired")
                                if !aired.isEmpty, !next.isEmpty { NowLine(at: t.date) }
                                grid(next)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .heroPage(hero != nil)
        .animation(.easeOut(duration: 0.3), value: hero == nil)
        .task { await store.loadSchedule() }
    }

    // "in 3h 20m", "in 12m", or "tomorrow 09:30" when it's further off.
    static func countdown(_ at: Date, now: Date) -> String {
        let m = Int(at.timeIntervalSince(now) / 60)
        if m < 1 { return "any minute now" }
        if m < 60 { return "in \(m)m" }
        if m < 12 * 60 { return "in \(m / 60)h \(m % 60)m" }
        return at.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    // Columns as the window allows, so the page isn't one long list down the left.
    @ViewBuilder func grid(_ items: [Airing]) -> some View {
        if !items.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(items) { s in
                    NavigationLink(value: s.anime) { ScheduleRow(s: s, status: store.list[s.anime.id]) }.buttonStyle(.plain)
                }
            }
        }
    }
}

// Between today's aired and upcoming episodes.
struct NowLine: View {
    let at: Date

    var body: some View {
        HStack(spacing: 8) {
            Text("Now · " + at.formatted(date: .omitted, time: .shortened)).font(.caption.bold()).foregroundStyle(Theme.pink)
            Capsule().fill(Theme.sunset).frame(height: 2)
        }
        .padding(.vertical, 6)
    }
}

struct ScheduleRow: View {
    let s: Airing
    let status: Entry?

    var body: some View {
        HStack(spacing: 12) {
            Text(s.at.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Poster(url: s.anime.poster, width: 36, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.anime.title).font(.headline).lineLimit(1)
                Text("Episode \(s.episode)" + (s.anime.episodes.map { " of \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let st = status {
                Text(st.favourite && st.status == nil ? "★" : (st.status?.rawValue ?? "") + (st.favourite ? " ★" : ""))
                    .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.sunset, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// One row of cards, paged with ‹ › like streaming apps; no scroll bar. Swiping still works.
struct Strip: View {
    @ObservedObject var store: Store
    let title: String
    let items: [Anime]
    var notes: (Anime) -> String? = { _ in nil }
    var id: String? // keeps scroll position apart for rows sharing a title (each show's Related row)
    var key: String { id ?? title }

    static let step: CGFloat = 140 + 18 // card width + gap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { // the row's hover headroom spaces it from the title (and keeps a grown card off it)
            SectionTitle(title)
            PagedRow(store: store, key: key) {
                ForEach(items) { a in CardLink(store: store, a: a, note: notes(a), row: key) }
            }
        }
        .id(key) // the arrow keys scroll the page to this row
    }
}

// The paging part of a row: ‹ › on hover, exact one-page jumps, no scroll bar.
struct PagedRow<Content: View>: View {
    @ObservedObject var store: Store
    let key: String
    var step: CGFloat = Strip.step // item width + 18pt gap
    var height: CGFloat = 284
    var top: CGFloat = 22 // headroom for the card hover lift
    var arrowHeight: CGFloat = 200
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let page = CGFloat(max(1, Int((geo.size.width + 18) / step))) * step
            let x = store.rowX[key] ?? 0, end = store.rowEnd[key] ?? 0
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) { content() } // not lazy: a lazy row draws blanks after paging
                    .padding(.top, top)
                    .padding(.horizontal, 6) // so the first and last cards aren't clipped when they grow
                    .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            // Scrolls only this row by an exact distance (scrolling *to a card* would also move the page).
            .scrollPosition(Binding(get: { store.rowScroll[key] ?? ScrollPosition() }, set: { store.rowScroll[key] = $0 }))
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.x, $0.contentSize.width - $0.containerSize.width, $0.containerSize.width] } action: { _, v in
                store.rowX[key] = v[0]
                store.rowEnd[key] = v[1]
                store.rowWidth[key] = v[2]
            }
            .scrollTargetBehavior(.viewAligned)
            .overlay(alignment: .topLeading) {
                if store.hoverRow == key, x > 1 { chevron("chevron.left", leading: true) { go(x - page, end) }.help("Previous") }
            }
            .overlay(alignment: .topTrailing) {
                if store.hoverRow == key, x < end - 1 { chevron("chevron.right", leading: false) { go(x + page, end) }.help("More") }
            }
        }
        .frame(height: height)
        .onHover { inside in
            if inside { store.hoverRow = key } else if store.hoverRow == key { store.hoverRow = nil }
        }
    }

    // Lands on an item edge, except at the very end of the row.
    func go(_ x: CGFloat, _ end: CGFloat) {
        var p = store.rowScroll[key] ?? ScrollPosition()
        p.scrollTo(x: min(max(0, (x / step).rounded() * step), end))
        withAnimation(.easeInOut(duration: 0.35)) { store.rowScroll[key] = p }
    }

    func chevron(_ symbol: String, leading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .frame(width: 54, height: arrowHeight)
                .background(LinearGradient(colors: [Theme.night.opacity(0.85), .clear], startPoint: leading ? .leading : .trailing, endPoint: leading ? .trailing : .leading))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, top) // line up with the items, below the headroom
        .transition(.opacity)
    }
}

// A character with their voice actor's photo tucked in the corner.
struct CastTile: View {
    let c: CastMember
    let english: Bool

    var body: some View {
        let va = english ? c.english : c.japanese
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                FadeImage(url: c.image).frame(width: 104, height: 104).clipShape(Circle())
                if let va {
                    FadeImage(url: va.image)
                        .frame(width: 54, height: 54)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 3))
                        .offset(x: 26, y: 4)
                        .help(va.name)
                }
            }
            .frame(width: 150, height: 112, alignment: .leading)
            .padding(.bottom, 4)
            Text(c.name).font(.headline).lineLimit(2)
            Text(c.role).font(.caption).foregroundStyle(.secondary)
            if let va {
                Label(va.name, systemImage: "mic").font(.subheadline).lineLimit(1).padding(.top, 2)
            }
        }
        .frame(width: 150, alignment: .leading)
    }
}

struct Shelf: View {
    @ObservedObject var store: Store
    let title: String
    let items: [Anime]
    var notes: (Anime) -> String? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                ForEach(items) { a in
                    CardLink(store: store, a: a, note: notes(a), row: title).id(title + "|" + a.id)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { store.gridCols = max(1, Int(($0 + 18) / (140 + 18))) }
        }
    }
}

// The status choices, shared by the card's ＋ menu and the details page.
struct StatusItems: View {
    @ObservedObject var store: Store
    let a: Anime

    var body: some View {
        let e = store.list[a.id]
        ForEach(Status.allCases, id: \.self) { s in
            Button { store.setStatus(a, s) } label: {
                if e?.status == s { Label(s.rawValue, systemImage: "checkmark") } else { Text(s.rawValue) }
            }
        }
        if e?.status != nil {
            Divider()
            Button("Remove from My list…") { store.confirmRemove = a } // asks first
        }
    }
}

// A card that opens the show, with ☆ and ＋ buttons on hover (kept visible once set).
struct CardLink: View {
    @ObservedObject var store: Store
    let a: Anime
    var note: String?
    var row = "" // the same show can sit in several rows; only the card under the pointer lights up
    var hoverKey: String { row + "|" + a.id }

    var body: some View {
        let e = store.list[a.id]
        let hover = store.hoverCard == hoverKey
        NavigationLink(value: a) { Card(a: a, note: note) }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if hover || e?.favourite == true {
                        Button { store.toggleFavourite(a) } label: {
                            CardIcon(symbol: e?.favourite == true ? "star.fill" : "star", tint: e?.favourite == true ? Theme.gold : .white)
                        }
                        .buttonStyle(.plain)
                        .help(e?.favourite == true ? "Remove from Favourites" : "Add to Favourites")
                    }
                    if hover || e?.status != nil {
                        Menu { StatusItems(store: store, a: a) } label: {
                            CardIcon(symbol: e?.status == nil ? "plus" : "checkmark", tint: .white, lit: e?.status != nil)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(e?.status.map { "On My list: \($0.rawValue). Click to change" } ?? "Add to My list")
                    }
                }
                .padding(7)
            }
            .shadow(color: Theme.pink.opacity(hover ? 0.55 : 0), radius: 18, y: 6)
            .scaleEffect(hover ? 1.08 : 1, anchor: .bottom)
            .zIndex(hover ? 1 : 0) // draw over its neighbours
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { inside in
                if inside { store.hoverCard = hoverKey } else if store.hoverCard == hoverKey { store.hoverCard = nil }
            }
    }
}

struct CardIcon: View {
    let symbol: String
    let tint: Color
    var lit = false // on My list: sunset-filled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(lit ? AnyShapeStyle(Theme.sunset) : AnyShapeStyle(Theme.night.opacity(0.7)), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
            .contentShape(Circle())
    }
}

struct Card: View {
    let a: Anime
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Poster(url: a.poster, width: 140, height: 200)
            Text(a.title).font(.headline).lineLimit(2, reservesSpace: true) // star lines stay level across a row
            HStack(spacing: 4) {
                if let sc = a.score { Image(systemName: "star.fill").foregroundStyle(Theme.gold); Text("\(sc) ·") }
                Text([a.year, a.format].compactMap { $0 }.joined(separator: " · "))
            }
            .font(.caption).foregroundStyle(.secondary)
            if let note { Text(note).font(.caption.bold()).foregroundStyle(Theme.sunset) }
        }
        .frame(width: 140, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: Loading placeholders: grey shapes with a soft moving shine, so nothing just pops in.

struct Shimmer: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation) { t in
            let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            content.overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.5)
                        .offset(x: -g.size.width * 0.5 + g.size.width * 1.5 * phase)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 140, height: 200)
            Capsule().fill(.quaternary).frame(width: 120, height: 12)
            Capsule().fill(.quaternary).frame(width: 80, height: 10)
        }
        .frame(width: 140, alignment: .leading)
    }
}

struct SkeletonStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(.quaternary).frame(width: 180, height: 20)
            // An overlay, so the row fills the width it's given instead of widening the page.
            Color.clear.frame(height: 240)
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 18) { ForEach(0..<10, id: \.self) { _ in SkeletonCard() } }
                }
                .clipped()
        }
        .padding(.top, 6)
        .shimmer()
    }
}

struct SkeletonGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(.quaternary).frame(width: 220, height: 20)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                ForEach(0..<12, id: \.self) { _ in SkeletonCard() }
            }
        }
        .shimmer()
    }
}

struct SkeletonLines: View {
    let widths: [CGFloat]
    var height: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: height * 0.9) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, w in Capsule().fill(.quaternary).frame(width: w, height: height) }
        }
        .shimmer()
    }
}

struct SkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<8, id: \.self) { i in
                HStack(spacing: 12) {
                    Capsule().fill(.quaternary).frame(width: 44, height: 12).padding(.trailing, 20)
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 36, height: 52)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(.quaternary).frame(width: [260, 200, 320, 180][i % 4], height: 13)
                        Capsule().fill(.quaternary).frame(width: 90, height: 10)
                    }
                }
            }
        }
        .shimmer()
    }
}

// The synopsis, book-page style: comfortable size and spacing, the source as a small credit, long ones folded.
struct Synopsis: View {
    @ObservedObject var store: Store
    let id: String
    let text: String

    // "...adventure.\n\n(Source: Crunchyroll)" -> ("...adventure.", "Crunchyroll")
    static func split(_ s: String) -> (body: String, source: String?) {
        let pattern = #"\s*[\(\[](?:Source|Written by)\s*:?\s*([^\)\]]+)[\)\]]\s*$"#
        guard let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return (s, nil) }
        let src = s[r].replacingOccurrences(of: #"^\s*[\(\[](?:Source|Written by)\s*:?\s*|[\)\]]\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return (String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), src)
    }

    var body: some View {
        let (body, source) = Self.split(text)
        let long = body.count > 480
        let open = store.expandedLinks.contains("synopsis:" + id)
        VStack(alignment: .leading, spacing: 10) {
            Text(body)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(long && !open ? 5 : nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if long {
                    Button(open ? "Show less" : "Read more") {
                        withAnimation(.easeOut(duration: 0.25)) {
                            if open { store.expandedLinks.remove("synopsis:" + id) } else { store.expandedLinks.insert("synopsis:" + id) }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.sunset)
                }
                if let source { Text("Synopsis from \(source)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

// Tries each image in turn (a missing one falls through to the next); last resort is the top of the poster, fading out.
struct BannerImage: View {
    let urls: [URL]
    let poster: URL?

    var body: some View {
        if let first = urls.first {
            AsyncImage(url: first, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                case .failure: AnyView(BannerImage(urls: Array(urls.dropFirst()), poster: poster))
                default: Rectangle().fill(.quaternary).shimmer()
                }
            }
        } else {
            GeometryReader { g in
                FadeImage(url: poster)
                    .frame(width: g.size.width, height: g.size.width * 1.4, alignment: .top) // poster shape, top part shows
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(colors: [.black, .black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

// An image that shimmers while loading and fades in when it arrives.
struct FadeImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            case .failure: Color.secondary.opacity(0.15).overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            default: Rectangle().fill(.quaternary).shimmer()
            }
        }
    }
}

struct Poster: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        FadeImage(url: url)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DetailView: View {
    @ObservedObject var store: Store
    let anime: Anime

    var body: some View {
        let a = store.details[anime.id] ?? anime
        let loading = store.details[anime.id] == nil
        ScrollView {
            hero(a, loading: loading)
            VStack(alignment: .leading, spacing: 28) {
                // Synopsis with the remaining facts beside it; stacked when the window is narrow.
                if store.detailWidth >= 760 {
                    HStack(alignment: .top, spacing: 48) {
                        synopsis(a, loading: loading)
                        stats(a, loading: loading).fixedSize()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        synopsis(a, loading: loading)
                        stats(a, loading: loading)
                    }
                }
                if loading {
                    SkeletonStrip().transition(.identity)
                } else {
                whereToWatch(a)
                if let cast = a.cast, !cast.isEmpty {
                    let hasEnglish = cast.contains { $0.english != nil }
                    let english = hasEnglish && store.englishCast
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            SectionTitle("Characters & cast")
                            Spacer()
                            if hasEnglish {
                                Button { store.englishCast = false } label: { Text("Japanese") }.buttonStyle(ChipStyle(active: !english))
                                    .help("Original Japanese voice cast")
                                Button { store.englishCast = true } label: { Text("English") }.buttonStyle(ChipStyle(active: english))
                                    .help("English dub voice cast")
                            }
                        }
                        PagedRow(store: store, key: "cast:" + anime.id, step: 150 + 18, height: 210, top: 10, arrowHeight: 112) {
                            ForEach(Array(cast.enumerated()), id: \.offset) { CastTile(c: $0.element, english: english) }
                        }
                    }
                }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading) // full width even when nothing below is wide
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { store.detailWidth = $0 }
            .animation(.easeOut(duration: 0.35), value: loading)
            moreToWatch(a, loading: loading)
        }
        .ignoresSafeArea(edges: .top) // the picture runs up under the toolbar
        .background(Theme.skyBottom.ignoresSafeArea()) // one colour under the picture, so its fade has nothing to meet
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle("") // the title is on the picture
        .sheet(item: $store.playing) { t in TrailerPlayer(store: store, trailer: t, title: a.title) }
        .task { await store.loadDetail(anime) }
    }

    // Related + recommendations in their own full-width band, set apart from the show's own details.
    @ViewBuilder func moreToWatch(_ a: Anime, loading: Bool) -> some View {
        let rel = a.related ?? [], recs = a.recommended ?? []
        if !loading, !rel.isEmpty || !recs.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                if !rel.isEmpty {
                    let label = Dictionary(rel.map { ($0.anime.id, $0.relation) }, uniquingKeysWith: { a, _ in a })
                    Strip(store: store, title: "Related", items: rel.map(\.anime), notes: { label[$0.id] }, id: "related:" + anime.id)
                }
                if !recs.isEmpty {
                    Strip(store: store, title: "If you liked this", items: recs, id: "recs:" + anime.id)
                }
            }
            .padding(24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.band)
            .overlay(alignment: .top) { Rectangle().fill(Theme.sunset).frame(height: 2) } // the line between this show and more to watch
            .transition(.opacity)
        }
    }

    @ViewBuilder func stats(_ a: Anime, loading: Bool) -> some View {
        if loading { SkeletonLines(widths: [180, 150, 120, 110, 130]).transition(.identity) }
        else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("Started", prettyDate(a.start))
                row("Ended", prettyDate(a.end))
                row("Seasons", seasons(a))
                row("Fans", a.popularity?.formatted())
                row("Studio", a.studio)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder func synopsis(_ a: Anime, loading: Bool) -> some View {
        if loading { SkeletonLines(widths: [420, 440, 400, 430, 260], height: 13).transition(.identity) }
        else if !a.synopsis.isEmpty { Synopsis(store: store, id: anime.id, text: a.synopsis).frame(maxWidth: 560, alignment: .leading).transition(.opacity) } // ~75 characters a line, book-like
    }

    func seasons(_ a: Anime) -> String? {
        if let s = store.watch[anime.id]?.seasons { return "\(s)" }
        guard let n = a.tvSeasons, n > 0 else { return nil }
        return (a.seasonsMore ? "\(n)+" : "\(n)") + (n == 1 && !a.seasonsMore ? " TV part" : " TV parts")
    }

    @ViewBuilder func row(_ k: String, _ v: String?) -> some View {
        if let v { GridRow { Text(k).foregroundStyle(.secondary); Text(v).textSelection(.enabled) } }
    }

    static let heroHeight: CGFloat = 520

    // A full-width picture with the show laid over its lower left, like a cinema poster wall.
    @ViewBuilder func hero(_ a: Anime, loading: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            HeroPicture(a: a, height: Self.heroHeight, loading: loading)
            HeroShade()
            HStack(alignment: .bottom, spacing: 28) {
                Poster(url: a.poster, width: 170, height: 246).shadow(color: .black.opacity(0.6), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 12) {
                    if let n = a.native { Text(n).font(.title3).foregroundStyle(.white.opacity(0.7)).textSelection(.enabled) }
                    Text(a.title).font(.system(size: 44, weight: .heavy)).foregroundStyle(.white).lineLimit(2).textSelection(.enabled)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                    if !loading { HeroFacts(a: a) }
                    if let ep = a.nextEpisode, let at = a.nextAiring, at > Date() {
                        Label("Episode \(ep) airs " + at.formatted(.dateTime.weekday(.wide).day().month().hour().minute()), systemImage: "calendar")
                            .font(.headline).foregroundStyle(Theme.gold)
                    }
                    HStack(spacing: 8) {
                        if let t = a.trailer {
                            Button { store.playing = t } label: { Label("Play trailer", systemImage: "play.fill") }
                                .buttonStyle(ChipStyle(active: true))
                                .help("Play the trailer")
                        }
                        ListControls(store: store, anime: anime).fixedSize()
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            .environment(\.colorScheme, .dark) // white on the picture, in Light mode too
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .frame(height: Self.heroHeight)
        .animation(.easeOut(duration: 0.35), value: loading)
    }

    @ViewBuilder func whereToWatch(_ a: Anime) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Where to watch")
            if !store.hasWatchKey {
                Text("Add a free key to see what's streaming in \(store.regionName), with links straight to the show. It takes about two minutes.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Link(destination: URL(string: "https://www.movieofthenight.com/about/api")!) { Label("Get a free Movie of the Night key", systemImage: "key") }
                        .buttonStyle(ChipStyle())
                        .help("Opens Movie of the Night's Streaming Availability API page")
                    SettingsLink { Label("Paste it in Settings", systemImage: "gearshape") }
                        .buttonStyle(ChipStyle())
                        .help("Opens Otaku's Settings (⌘,)")
                }
            } else if let w = store.watch[anime.id] {
                if w.tmdbId == nil {
                    Text("Couldn't find this show on \(w.source == "Movie of the Night" ? "Movie of the Night" : "TMDB").").foregroundStyle(.secondary)
                } else {
                    if !w.stream.isEmpty {
                        Text("Streaming in \(store.regionName)").font(.headline)
                        Buttons(items: w.stream.compactMap { p in (w.direct[p] ?? directLink(p, a.links) ?? w.link).map { (p, $0) } }, id: "stream:" + anime.id)
                    }
                    if !w.buy.isEmpty {
                        Text("Rent or buy in \(store.regionName)").font(.headline)
                        Buttons(items: w.buy.compactMap { p in (w.direct[p] ?? directLink(p, a.links) ?? w.link).map { (p, $0) } }, id: "buy:" + anime.id)
                    }
                    if w.stream.isEmpty, w.buy.isEmpty {
                        Text("Not available in \(store.regionName) right now.").foregroundStyle(.secondary)
                    }
                    if !w.networks.isEmpty {
                        Text("Originally aired on: " + w.networks.joined(separator: ", "))
                    }
                    Text("Availability from \(w.source) · matched “\(w.name)”\(w.year.map { " (\($0))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !w.candidates.isEmpty {
                    FilterChip(icon: "questionmark.circle", label: "Wrong match?", active: false, tip: "Pick the right show") {
                        ForEach(w.candidates) { c in
                            Button(c.name + (c.year.map { " (\($0))" } ?? "")) { store.choose(anime, c.id) }
                        }
                        Divider()
                        Button("None of these") { store.choose(anime, -1) }
                    }
                }
            } else {
                HStack(spacing: 8) { ForEach([110.0, 90, 130], id: \.self) { Capsule().fill(.quaternary).frame(width: $0, height: 32) } }.shimmer()
            }
            if !a.links.isEmpty {
                Text("All streaming links").font(.headline).padding(.top, 6)
                Text("Worldwide list: not every service carries it in every country.").font(.caption).foregroundStyle(.secondary)
                Buttons(items: a.links.map { ($0.site + ($0.note.map { " (\($0))" } ?? ""), $0.url) }, id: "all:" + anime.id)
            }
        }
    }
}

// Streaming links as pills that wrap onto new lines.
// Plays a trailer in the app; closing the sheet stops it.
struct TrailerPlayer: View {
    @ObservedObject var store: Store
    let trailer: Trailer
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if let page = trailer.page {
                    Link(destination: page) { Label("Open on \(trailer.siteName)", systemImage: "arrow.up.right") }
                        .buttonStyle(ChipStyle())
                        .focusable(false)
                }
                Button { store.playing = nil } label: { Label("Done", systemImage: "xmark") }
                    .buttonStyle(ChipStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            WebPlayer(html: trailer.playerHTML).frame(width: 960, height: 540)
        }
    }
}

struct WebPlayer: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = [] // autoplay
        let web = WKWebView(frame: .zero, configuration: config)
        // YouTube identifies embedding apps by this origin: https:// + the app's bundle id.
        web.loadHTMLString(html, baseURL: URL(string: "https://" + (Bundle.main.bundleIdentifier ?? "local.otaku")))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}
}

// Streaming links as pills: variants of one service share a pill (Hoopla Sub/Dub → Hoopla ⌄),
// big services first, and only the first few until "+N more".
struct Buttons: View {
    @ObservedObject var store = Store.shared
    let items: [(String, URL)]
    var id = ""

    static let first = ["crunchyroll", "netflix", "amazon prime video", "prime video", "disney plus", "disney+", "hulu", "hidive", "max"]

    static func group(_ items: [(String, URL)]) -> [(name: String, variants: [(String, URL)])] {
        var out: [(name: String, variants: [(String, URL)])] = []
        for (label, url) in items {
            let name = label.components(separatedBy: " (")[0]
            let variant = label.count > name.count ? String(label.dropFirst(name.count + 2).dropLast()) : name
            if let i = out.firstIndex(where: { $0.name == name }) { out[i].variants.append((variant, url)) } else { out.append((name, [(variant, url)])) }
        }
        let rank = { (n: String) in first.firstIndex(of: n.lowercased()) ?? first.count }
        return out.enumerated().sorted { (rank($0.element.name), $0.offset) < (rank($1.element.name), $1.offset) }.map(\.element)
    }

    var body: some View {
        let groups = Self.group(items)
        let open = store.expandedLinks.contains(id)
        let shown = open || groups.count <= 7 ? groups : Array(groups.prefix(6))
        Flow(spacing: 8) {
            ForEach(shown, id: \.name) { g in
                if g.variants.count == 1, let v = g.variants.first {
                    Link(destination: v.1) { Label(v.0 == g.name ? g.name : "\(g.name) (\(v.0))", systemImage: "play.fill") }
                        .buttonStyle(ChipStyle())
                        .help("Open \(g.name)")
                } else {
                    FilterChip(icon: "play.fill", label: g.name, active: false, tip: "\(g.variants.count) ways to watch on \(g.name)") {
                        ForEach(g.variants, id: \.0) { v in Button(v.0) { NSWorkspace.shared.open(v.1) } }
                    }
                }
            }
            if groups.count > shown.count {
                Button { store.expandedLinks.insert(id) } label: { Text("+\(groups.count - shown.count) more") }
                    .buttonStyle(ChipStyle())
                    .help("Show all services")
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

// Lays children left to right, wrapping when a row is full.
struct Flow: Layout {
    var spacing: CGFloat = 8

    func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]], x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let r = rows(width, subviews)
        let h = r.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, r.count - 1))
        let w = r.map { $0.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += (row.map(\.1.height).max() ?? 0) + spacing
        }
    }
}

struct ChipStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .chip(active: active)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .focusEffectDisabled()
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Otaku").font(.title.bold())
                    Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            SettingsCard(title: "Appearance") {
                HStack(spacing: 8) {
                    ForEach(Appearance.allCases, id: \.self) { a in
                        Button { store.appearance = a } label: { Label(a.rawValue, systemImage: a.icon) }
                            .buttonStyle(ChipStyle(active: store.appearance == a))
                            .focusable(false)
                            .help(a == .auto ? "Follow your Mac's light or dark setting" : "Always \(a.rawValue.lowercased())")
                    }
                }
            }

            SettingsCard(title: "New episode alerts") {
                SettingsSwitch(title: "Tell me when a new episode is out", isOn: $store.alertsOn)
                SettingsSwitch(title: "Show in the menu bar", isOn: $store.inMenuBar)
                SettingsSwitch(title: "Open Otaku at login", isOn: Binding(get: { Alerts.openAtLogin }, set: { Alerts.openAtLogin = $0; store.objectWillChange.send() }))
                Text("Covers shows on My list that aren't Finished. Alerts only arrive while Otaku is running; closing its window keeps it running. The menu bar shows what from My list airs today.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Import my list") {
                HStack(spacing: 10) {
                    TextField("AniList user name", text: $store.anilistUser)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge))
                        .onSubmit { Task { await store.importAniList() } }
                    Button { Task { await store.importAniList() } } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .buttonStyle(ChipStyle())
                        .focusable(false)
                        .disabled(store.importing || store.anilistUser.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Add your public AniList list and favourites to My list")
                }
                HStack(spacing: 8) {
                    Button { Task { await store.importMAL() } } label: { Label("Import MyAnimeList export…", systemImage: "doc.badge.arrow.up") }
                        .buttonStyle(ChipStyle())
                        .focusable(false)
                        .disabled(store.importing)
                        .help("Choose the .xml or .xml.gz file MyAnimeList gives you")
                    Link(destination: URL(string: "https://myanimelist.net/panel.php?go=export")!) { Label("Export from MyAnimeList", systemImage: "arrow.up.right") }
                        .buttonStyle(ChipStyle())
                        .focusable(false)
                        .help("Opens MyAnimeList's export page in your browser")
                    if store.importing { ProgressView().controlSize(.small) }
                }
                Text(store.importNote ?? "Adds shows to My list with their status (watching, planned, finished); dropped shows are skipped. Shows already on My list keep their status.")
                    .font(.caption).foregroundStyle(store.importNote == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.gold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Where to watch") {
                KeyField(prompt: "Paste your Movie of the Night key", text: $store.motnKey, saved: !store.motn.isEmpty)
                Text("Recommended. Shows what's streaming in \(store.regionName) (from your Mac's region), with links straight to the show. Keys from Movie of the Night or from RapidAPI both work.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://www.movieofthenight.com/about/api")!) { Label("Get a free Movie of the Night key", systemImage: "key") }
                    .buttonStyle(ChipStyle())
                    .focusable(false)
                Divider().padding(.vertical, 4)
                HStack(spacing: 10) {
                    SecureField("Paste your TMDB key", text: $store.tmdbKey)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge))
                    if store.key.isEmpty {
                        Label("No key", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    } else {
                        Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.gold)
                    }
                }
                Text("Optional extra, for personal use: adds where a show first aired, and is used when Movie of the Night can't help. The API key or the read access token both work.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://www.themoviedb.org/settings/api")!) { Label("Get a free TMDB key", systemImage: "key") }
                    .buttonStyle(ChipStyle())
                    .focusable(false)
            }

            SettingsCard(title: "About") {
                Text("Anime data from AniList, with Kitsu as a backup. Streaming availability from Movie of the Night, or JustWatch via TMDB.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Link(destination: URL(string: "https://anilist.co")!) { Text("AniList") }.buttonStyle(ChipStyle()).focusable(false)
                    Link(destination: URL(string: "https://kitsu.app")!) { Text("Kitsu") }.buttonStyle(ChipStyle()).focusable(false)
                    Link(destination: URL(string: "https://www.themoviedb.org")!) { Text("TMDB") }.buttonStyle(ChipStyle()).focusable(false)
                    Link(destination: URL(string: "https://www.justwatch.com")!) { Text("JustWatch") }.buttonStyle(ChipStyle()).focusable(false)
                }
            }

            HStack {
                Spacer()
                Button { uninstall() } label: {
                    Label("Uninstall Otaku…", systemImage: "trash")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .foregroundStyle(Color.red)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.red.opacity(0.45)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Removes My list, saved data and settings, then moves Otaku to the Trash")
            }
        }
        .toggleStyle(.switch)
        .padding(24)
        .frame(width: 520)
        .background(Theme.sky.ignoresSafeArea())
    }
}

// Label on the left, switch lined up on the right.
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().focusable(false)
        }
    }
}

// A key entry box with a "Key saved" / "No key" note beside it.
struct KeyField: View {
    let prompt: String
    @Binding var text: String
    let saved: Bool

    var body: some View {
        HStack(spacing: 10) {
            SecureField(prompt, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge))
            if saved { Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.gold) }
            else { Label("No key", systemImage: "circle.dashed").foregroundStyle(.secondary) }
        }
    }
}

// A rounded group with a sunset-bar heading.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Capsule().fill(Theme.sunsetTall).frame(width: 3, height: 16)
                Text(title).font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.edge.opacity(0.7)))
    }
}

// Like Scout's: confirm, remove everything Otaku keeps on this Mac, move the app to the Trash, quit.
@MainActor func uninstall() {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Uninstall Otaku?"
    alert.informativeText = "This deletes My list (\(Store.shared.list.count) shows), saved data and settings including your TMDB key, turns off Open at login, moves the app to the Trash and quits. It can't be undone."
    alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let fm = FileManager.default
    try? fm.removeItem(at: Store.listFile.deletingLastPathComponent()) // Application Support/Otaku: My list
    try? fm.removeItem(at: Cache.dir) // Caches/Otaku
    try? SMAppService.mainApp.unregister()
    if Alerts.available {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.otaku")
    UserDefaults.standard.synchronize()
    // Only ever trash an .app: run from the build folder, the "bundle" is the build directory itself.
    let app = Bundle.main.bundleURL
    guard app.pathExtension == "app" else { NSApp.terminate(nil); return }
    NSWorkspace.shared.recycle([app]) { _, _ in NSApp.terminate(nil) }
}

// "2023-09-29" → "29 Sep 2023", "2023-09" → "Sep 2023"; a bare year stays as it is.
func prettyDate(_ s: String?) -> String? {
    guard let s else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for (from, to) in [("yyyy-MM-dd", "d MMM yyyy"), ("yyyy-MM", "MMM yyyy")] where s.count == from.count {
        f.dateFormat = from
        if let d = f.date(from: s) { f.locale = .current; f.setLocalizedDateFormatFromTemplate(to); return f.string(from: d) }
    }
    return s
}

// The big picture at the top of a page. It scrolls at half speed, so the page seems to slide over it.
struct HeroPicture: View {
    let a: Anime
    let height: CGFloat
    var loading = false

    var body: some View {
        // In an overlay so a wide picture fills the space instead of widening the page.
        Color.clear.frame(maxWidth: .infinity).frame(height: height)
            .overlay {
                if loading { Rectangle().fill(.quaternary).shimmer() }
                // Its own banner (or one borrowed from the series), else the trailer's still, else the top of the poster.
                else { BannerImage(urls: [a.banner, a.trailer?.still].compactMap { $0 }, poster: a.poster) }
            }
            .visualEffect { c, g in c.offset(y: max(0, -g.frame(in: .scrollView).minY) * 0.5) }
            .clipped()
    }
}

extension View {
    // A page whose hero picture runs up under the toolbar, over one solid colour so the picture's fade has nothing to meet.
    func heroPage(_ on: Bool) -> some View {
        ignoresSafeArea(edges: on ? .top : [])
            .background { if on { Theme.skyBottom.ignoresSafeArea() } }
    }
}

// Night on the left for the words, melting into the page at the bottom. Under the show page's and the carousel's pictures.
struct HeroShade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Theme.night.opacity(0.92), location: 0), .init(color: Theme.night.opacity(0.55), location: 0.45), .init(color: .clear, location: 0.8)],
                       startPoint: .leading, endPoint: .trailing)
        LinearGradient(stops: [.init(color: Theme.night.opacity(0.45), location: 0), .init(color: .clear, location: 0.25),
                               .init(color: .clear, location: 0.5), .init(color: Theme.skyBottom, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// ★ 90  2023 · TV · 28 episodes · Finished, then genre pills.
struct HeroFacts: View {
    let a: Anime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let sc = a.score { Label("\(sc)", systemImage: "star.fill").foregroundStyle(Theme.gold).fontWeight(.bold) }
                Text([a.year, a.format, a.episodes.map { "\($0) episodes" }, a.status].compactMap { $0 }.joined(separator: "  ·  "))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .font(.title3.weight(.medium))
            if !a.genres.isEmpty {
                HStack(spacing: 6) {
                    ForEach(a.genres.prefix(5), id: \.self) { g in
                        Text(g).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.white.opacity(0.12), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                    }
                }
            }
        }
        .transition(.opacity)
    }
}

// Add to My list + Favourite pills. Pass the card's `anime` so the entry matches wherever the show is opened from.
struct ListControls: View {
    @ObservedObject var store: Store
    let anime: Anime

    var body: some View {
        let e = store.list[anime.id]
        HStack(spacing: 8) {
            // Both pills keep one width whatever they say, so nothing beside them re-wraps.
            FilterChip(icon: e?.status == nil ? "plus" : "checkmark", label: e?.status?.rawValue ?? "Add to My list", active: e?.status != nil,
                       tip: e?.status == nil ? "Add to My list" : "Change or remove", sizedFor: ["Add to My list"] + Status.allCases.map(\.rawValue)) {
                StatusItems(store: store, a: anime)
            }
            Button { store.toggleFavourite(anime) } label: {
                ZStack {
                    Label("Add to Favourites", systemImage: "star").hidden()
                    Label(e?.favourite == true ? "Favourite" : "Add to Favourites", systemImage: e?.favourite == true ? "star.fill" : "star")
                }
            }
            .buttonStyle(ChipStyle(active: e?.favourite == true))
            .help(e?.favourite == true ? "Remove from Favourites" : "Add to Favourites")
        }
    }
}

// The start page's big picture: your new episodes, then what's trending. Moves on every 8 seconds; hovering holds it.
struct Carousel: View {
    @ObservedObject var store: Store
    let slides: [Slide]
    static let height: CGFloat = 470
    // Kept in the store, like the rest of the app's view state.
    var i: Int { get { min(store.slide, slides.count - 1) } nonmutating set { store.slide = newValue } }
    var hover: Bool { get { store.slideHover } nonmutating set { store.slideHover = newValue } }

    var body: some View {
        let s = slides[i], a = s.anime
        ZStack(alignment: .bottomLeading) {
            HeroPicture(a: a, height: Self.height).id(a.id).transition(.opacity)
            HeroShade()
            VStack(alignment: .leading, spacing: 12) {
                Text(s.note.uppercased()).font(.caption.weight(.heavy)).tracking(1.5).foregroundStyle(Theme.gold)
                Text(a.title).font(.system(size: 42, weight: .heavy)).foregroundStyle(.white).lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                HeroFacts(a: a)
                let body = Synopsis.split(a.synopsis).body
                if !body.isEmpty {
                    Text(body).font(.system(size: 15)).lineSpacing(4).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                        .frame(maxWidth: 600, alignment: .leading)
                }
                HStack(spacing: 8) {
                    NavigationLink(value: a) { Label("More info", systemImage: "info.circle") }
                        .buttonStyle(ChipStyle(active: true))
                        .help("Open \(a.title)")
                    ListControls(store: store, anime: a).fixedSize()
                }
                .padding(.top, 4)
            }
            .id(a.id).transition(.opacity)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottomTrailing) { if slides.count > 1 { dots.padding(.trailing, 24).padding(.bottom, 44) } }
        .overlay(alignment: .leading) { if hover, slides.count > 1 { arrow("chevron.left", -1).padding(.leading, 12) } }
        .overlay(alignment: .trailing) { if hover, slides.count > 1 { arrow("chevron.right", 1).padding(.trailing, 12) } }
        .environment(\.colorScheme, .dark) // white on the picture, in Light mode too
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.6), value: i)
        .animation(.easeOut(duration: 0.15), value: hover)
        .task(id: "\(i) \(hover) \(slides.count)") { // restarts the 8 seconds after every move, and stops while hovered
            guard !hover, slides.count > 1 else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { i = (i + 1) % slides.count }
        }
    }

    var dots: some View {
        HStack(spacing: 6) {
            ForEach(slides.indices, id: \.self) { n in
                Button { i = n } label: {
                    Capsule().fill(n == i ? AnyShapeStyle(Theme.sunset) : AnyShapeStyle(.white.opacity(0.35)))
                        .frame(width: n == i ? 22 : 8, height: 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(slides[n].anime.title)
            }
        }
    }

    func arrow(_ symbol: String, _ step: Int) -> some View {
        Button { i = (i + step + slides.count) % slides.count } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(Theme.night.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .help(step < 0 ? "Previous" : "Next")
        .transition(.opacity)
    }
}

// A row of wide picture cards (My list's Watching), paged like the poster rows.
struct WideRow: View {
    @ObservedObject var store: Store
    let title: String
    let items: [Anime]
    var notes: (Anime) -> String? = { _ in nil }
    static let w: CGFloat = 300, h: CGFloat = 169

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title)
            PagedRow(store: store, key: "wide:" + title, step: Self.w + 18, height: Self.h + 56, arrowHeight: Self.h) {
                ForEach(items) { a in WideCard(store: store, a: a, note: notes(a), row: "wide:" + title) }
            }
        }
        .id(title)
    }
}

struct WideCard: View {
    @ObservedObject var store: Store
    let a: Anime
    var note: String?
    var row = ""
    var key: String { row + "|" + a.id }

    var body: some View {
        let hover = store.hoverCard == key
        NavigationLink(value: a) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    Color.clear.frame(width: WideRow.w, height: WideRow.h)
                        .overlay { BannerImage(urls: [a.banner, a.trailer?.still].compactMap { $0 }, poster: a.poster) }
                        .clipped()
                    LinearGradient(colors: [.clear, Theme.night.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    if let note { Text(note).font(.caption.weight(.heavy)).foregroundStyle(Theme.gold).padding(10) }
                }
                .frame(width: WideRow.w, height: WideRow.h)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(a.title).font(.headline).lineLimit(1)
            }
            .frame(width: WideRow.w, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shadow(color: Theme.pink.opacity(hover ? 0.55 : 0), radius: 18, y: 6)
        .scaleEffect(hover ? 1.04 : 1, anchor: .bottom)
        .zIndex(hover ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { inside in
            if inside { store.hoverCard = key } else if store.hoverCard == key { store.hoverCard = nil }
        }
        .help("Open \(a.title)")
    }
}
