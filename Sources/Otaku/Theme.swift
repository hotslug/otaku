import SwiftUI

// The logo's colours: a night sky with a pink → coral → gold sunset.
// Light mode is the same scene by day: white fading into pink, same sunset accents.
enum Theme {
    static let night = Color(hex: 0x120E2E) // on top of images, in both modes
    static let pink = Color(hex: 0xFF3D7F)
    static let coral = Color(hex: 0xFF7A59)
    static let gold = Color(dark: 0xFFD166, light: 0xE8A317) // deeper by day so stars stay readable

    static let skyTop = Color(dark: 0x2A1657, light: 0xFFFFFF)
    static let skyBottom = Color(dark: 0x120E2E, light: 0xF6C9DF)
    static let dusk = skyTop // toolbar
    static let band = Color(dark: 0x0C0920, light: 0xE8B6D2, darkAlpha: 0.75) // "more to watch"
    static let surface = Color(dark: 0xFFFFFF, light: 0x2A1657, darkAlpha: 0.08, lightAlpha: 0.10) // pills, cards, fields
    static let edge = Color(dark: 0xFFFFFF, light: 0x2A1657, darkAlpha: 0.12, lightAlpha: 0.18)

    static let sunset = LinearGradient(colors: [pink, coral], startPoint: .leading, endPoint: .trailing)
    static let sunsetTall = LinearGradient(colors: [gold, coral, pink], startPoint: .top, endPoint: .bottom)
    static let sky = LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom)
}

extension Color {
    init(hex: Int) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    // One colour per appearance; follows Light/Dark as it changes.
    init(dark: Int, light: Int, darkAlpha: Double = 1, lightAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

enum Appearance: String, CaseIterable {
    case auto = "Auto", light = "Light", dark = "Dark"

    var icon: String { ["Auto": "circle.lefthalf.filled", "Light": "sun.max", "Dark": "moon.stars"][rawValue]! }

    // NSApp.appearance switches every window at once, and nil goes back to following the Mac.
    func apply() {
        NSApp.appearance = self == .auto ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

// A section heading with a small sunset bar, like the stripes in the logo.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(Theme.sunsetTall).frame(width: 4, height: 22)
            Text(text).font(.title2.bold())
        }
    }
}
