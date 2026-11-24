import AppKit
import SwiftUI

// Keyboard: ⌘F jumps to search; arrows move a highlight between cards (the same look as hovering), Return opens it.
// One key watcher for the main window instead of SwiftUI focus, which fights the toolbar search field.
@MainActor enum Keys {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { handle(e) } ? nil : e
        }
    }

    static func searchField(_ w: NSWindow?) -> NSSearchField? {
        w?.toolbar?.items.lazy.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first
    }

    static func handle(_ e: NSEvent) -> Bool {
        let store = Store.shared, w = e.window
        guard let field = searchField(w) else { return false } // not the main window (Settings, a sheet…)
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, e.charactersIgnoringModifiers == "f" {
            w?.makeFirstResponder(field)
            return true
        }
        guard mods.isEmpty else { return false }
        if let editor = w?.firstResponder as? NSTextView { // typing somewhere
            // ↓ from the search box: on to the results
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
    // The cards on screen, row by row, in the same order the views draw them.
    var navRows: [NavRow] {
        guard path.isEmpty else { return [] }
        switch tab {
        case .discover:
            if let r = results { return r.isEmpty ? [] : [NavRow(key: resultsTitle, items: r, grid: true)] }
            return discoverRows.map { NavRow(key: $0.title, items: $0.items, grid: false) }
        case .list: return myListRows.map { NavRow(key: $0.title, items: $0.items, grid: false) }
        case .schedule: return []
        }
    }

    func firstVisible(_ row: NavRow) -> Int { row.grid ? 0 : Int(((rowX[row.key] ?? 0) / Strip.step).rounded()) }

    // Moves the highlight; with nothing highlighted yet, the first arrow just lights up a card.
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
        } else if dy != 0 { // same spot on screen in the row above/below
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
        // Page the row so the card is fully on screen.
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
