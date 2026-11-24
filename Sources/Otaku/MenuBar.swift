import AppKit
import SwiftUI

// The menu bar shortcut: what from My list airs today, and what's coming up this week.
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        let today = store.myEpisodes.filter { Calendar.current.isDateInToday($0.at) }.count
        Image(nsImage: Self.icon)
        if today > 0 { Text("\(today)") }
    }
}

extension MenuBarLabel {
    // The logo in one colour: the striped sun with the play button cut out of it.
    // A template image, so macOS draws it white or black to suit the menu bar.
    static let icon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15)).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for (y, h) in [(5.6, 0.9), (3.6, 1.2)] { NSRect(x: 0, y: y, width: 18, height: h).fill() } // stripes, low on the sun
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 7.2, y: 12.6))
            play.line(to: NSPoint(x: 12.6, y: 9.6))
            play.line(to: NSPoint(x: 7.2, y: 6.6))
            play.close()
            play.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

extension MenuBarLabel {
    // A torii gate, the "home" button when you've followed related shows a long way.
    static let torii: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            let top = NSBezierPath() // the kasagi: a top beam with upturned ends
            top.move(to: NSPoint(x: 0.5, y: 1))
            top.curve(to: NSPoint(x: 17.5, y: 1), controlPoint1: NSPoint(x: 6, y: 3.2), controlPoint2: NSPoint(x: 12, y: 3.2))
            top.line(to: NSPoint(x: 16.5, y: 4.2))
            top.curve(to: NSPoint(x: 1.5, y: 4.2), controlPoint1: NSPoint(x: 12, y: 5.6), controlPoint2: NSPoint(x: 6, y: 5.6))
            top.close(); top.fill()
            NSRect(x: 2.5, y: 7, width: 13, height: 1.8).fill() // the nuki
            NSRect(x: 4, y: 4, width: 1.9, height: 12).fill()   // pillars
            NSRect(x: 12.1, y: 4, width: 1.9, height: 12).fill()
            NSRect(x: 8.2, y: 4.5, width: 1.6, height: 2.5).fill() // the little strut between beams
            return true
        }
        img.isTemplate = true
        return img
    }()
}

struct MenuBarPanel: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let mine = store.myEpisodes
        let today = mine.filter { Calendar.current.isDateInToday($0.at) }
        let later = mine.filter { !Calendar.current.isDateInToday($0.at) && $0.at > Date() }.prefix(5)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("Otaku").font(.headline)
                Spacer()
            }

            SectionTitle("Airing today").font(.headline)
            if store.schedule == nil {
                SkeletonRows().frame(height: 120, alignment: .top).clipped()
            } else if store.list.isEmpty {
                Text("Add shows to My list to see when new episodes air.").font(.callout).foregroundStyle(.secondary)
            } else if today.isEmpty {
                Text("Nothing from My list airs today.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(today) { row($0) }
            }

            if !later.isEmpty {
                SectionTitle("Coming up this week").font(.headline).padding(.top, 4)
                ForEach(Array(later)) { row($0) }
            }

            Divider()
            HStack(spacing: 8) {
                Button { show(nil) } label: { Label("Open Otaku", systemImage: "macwindow") }.buttonStyle(ChipStyle())
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }.buttonStyle(ChipStyle())
                    .keyboardShortcut("q")
            }
            .focusable(false)
        }
        .padding(16)
        .frame(width: 360)
        .background(Theme.sky)
        .task { await store.loadSchedule() }
    }

    func row(_ s: Airing) -> some View {
        Button { show(s.anime) } label: {
            HStack(spacing: 10) {
                Poster(url: s.anime.poster, width: 30, height: 43)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.anime.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("Episode \(s.episode)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(when(s.at))
                    .font(.caption.bold()).monospacedDigit()
                    .foregroundStyle(s.at <= Date() ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.sunset))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(s.anime.title)")
    }

    func when(_ d: Date) -> String {
        if d <= Date() { return "aired " + d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInToday(d) { return d.formatted(.relative(presentation: .named)) }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // Brings the main window forward (opening one if it was closed), optionally on a show's page.
    func show(_ a: Anime?) {
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openWindow(id: "main") }
        if let a { store.tab = .list; store.path = [a] }
    }
}
