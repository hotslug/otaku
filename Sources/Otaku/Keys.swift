import AppKit
import SwiftUI

@MainActor enum Keys {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { handle(e) } ? nil : e
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { styleSearch(n.object as? NSWindow) }
        }
    }

    static func styleSearch(_ w: NSWindow?) {
        guard let f = searchField(w), let cell = f.cell as? NSSearchFieldCell else { return }
        cell.placeholderAttributedString = NSAttributedString(string: cell.placeholderString ?? "",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: f.font ?? .systemFont(ofSize: 13)])
    }

    static func searchField(_ w: NSWindow?) -> NSSearchField? {
        w?.toolbar?.items.lazy.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first
    }

    static func handle(_ e: NSEvent) -> Bool {
        let store = Store.shared, w = e.window
        guard let field = searchField(w) else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, e.charactersIgnoringModifiers == "f" {
            w?.makeFirstResponder(field)
            return true
        }
        guard mods.isEmpty else { return false }
        if let editor = w?.firstResponder as? NSTextView {
            guard editor.delegate as? NSSearchField === field, e.keyCode == 125, !store.navRows.isEmpty else { return false }
            w?.makeFirstResponder(nil)
            return store.arrow(0, 0)
        }
        switch e.keyCode {
        case 123: return store.arrow(-1, 0)
        case 124: return store.arrow(1, 0)
        case 125: return store.arrow(0, 1)
        case 126: return store.arrow(0, -1)
        case 36, 76: return store.openHighlighted()
        default: return false
        }
    }
}

struct NavRow { let key: String; let items: [Anime]; let grid: Bool }

extension Store {
    var navRows: [NavRow] {
        guard path.isEmpty else { return [] }
        switch tab {
        case .discover:
            if let r = results { return r.count < 2 ? [] : [NavRow(key: resultsTitle, items: Array(r.dropFirst()), grid: true)] }
            return discoverRows.map { NavRow(key: $0.title, items: $0.items, grid: false) }
        case .list: return myListRows.filter { $0.title != Status.watching.rawValue }.map { NavRow(key: $0.title, items: $0.items, grid: false) }
        case .schedule: return []
        }
    }

    func firstVisible(_ row: NavRow) -> Int { row.grid ? 0 : Int(((rowX[row.key] ?? 0) / Strip.step).rounded()) }

    func arrow(_ dx: Int, _ dy: Int) -> Bool {
        let rows = navRows
        guard !rows.isEmpty else { return false }
        guard var r = rows.firstIndex(where: { row in row.items.contains { hoverCard == row.key + "|" + $0.id } }),
              var i = rows[r].items.firstIndex(where: { hoverCard == rows[r].key + "|" + $0.id }) else {
            select(rows[0], firstVisible(rows[0]))
            return true
        }
        if rows[r].grid {
            i += dx + dy * max(1, gridCols)
        } else if dy != 0 {
            let col = i - firstVisible(rows[r])
            r = min(max(0, r + dy), rows.count - 1)
            i = firstVisible(rows[r]) + col
        } else {
            i += dx
        }
        select(rows[r], min(max(0, i), rows[r].items.count - 1))
        return true
    }

    func select(_ row: NavRow, _ i: Int) {
        let a = row.items[i]
        hoverRow = row.key
        hoverCard = row.key + "|" + a.id
        reveal = row.grid ? hoverCard : row.key
        guard !row.grid, let width = rowWidth[row.key] else { return }
        let visible = max(1, Int((width + 18) / Strip.step)), first = firstVisible(row)
        var x: CGFloat?
        if i < first { x = CGFloat(i) * Strip.step }
        if i >= first + visible { x = CGFloat(i - visible + 1) * Strip.step }
        if let x {
            var p = rowScroll[row.key] ?? ScrollPosition()
            p.scrollTo(x: min(x, rowEnd[row.key] ?? x))
            withAnimation(.easeInOut(duration: 0.25)) { rowScroll[row.key] = p }
        }
    }

    func openHighlighted() -> Bool {
        for row in navRows {
            if let a = row.items.first(where: { hoverCard == row.key + "|" + $0.id }) { path = [a]; return true }
        }
        return false
    }
}
