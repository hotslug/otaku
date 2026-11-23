import AppKit

// App icon: a striped "rising sun" with a play button inside it (anime + watch),
// on a night-sky tile with anime sparkles. Drawn in code; ./make-icon.sh turns it into Otaku.icns.
enum Icon {
    static func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func sparkle(_ c: NSPoint, _ r: CGFloat) {
        let p = NSBezierPath()
        let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
        p.move(to: tips[0])
        for t in tips.dropFirst() + [tips[0]] { p.curve(to: t, controlPoint1: c, controlPoint2: c) }
        p.fill()
    }

    static func draw() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

        // Soft drop shadow under the tile, like other macOS icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        color(0x140F33).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSGradient(starting: color(0x3A1A6E), ending: color(0x120E2E))!.draw(in: tile, angle: 90) // night sky, lighter at the horizon

        let sun = NSPoint(x: 512, y: 455), r: CGFloat = 255
        NSGradient(starting: color(0xFF4F8B, 0.55), ending: color(0xFF4F8B, 0))!
            .draw(fromCenter: sun, radius: r * 0.8, toCenter: sun, radius: r * 1.75, options: .drawsBeforeStartingLocation)

        // Sun with synthwave stripes cut out of its lower half.
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let disc = NSBezierPath(ovalIn: NSRect(x: sun.x - r, y: sun.y - r, width: 2 * r, height: 2 * r))
        NSGradient(colors: [color(0xFF3D7F), color(0xFF7A59), color(0xFFD166)])!.draw(in: disc, angle: 90)
        NSGraphicsContext.current!.compositingOperation = .destinationOut
        for (dy, h) in [(-30.0, 9.0), (-85, 15), (-140, 22), (-195, 30)] {
            NSRect(x: sun.x - r, y: sun.y + dy - h / 2, width: 2 * r, height: h).fill()
        }
        ctx.endTransparencyLayer()

        // Rounded white play button, nudged right so it looks centred.
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color(0x7A1E52, 0.6)
        glow.shadowBlurRadius = 30
        glow.shadowOffset = NSSize(width: 0, height: -8)
        glow.set()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil) // shadow the fill + rounded stroke once, as one shape
        let play = NSBezierPath()
        let cx = sun.x + 18
        play.move(to: NSPoint(x: cx - 80, y: sun.y + 115))
        play.line(to: NSPoint(x: cx + 120, y: sun.y))
        play.line(to: NSPoint(x: cx - 80, y: sun.y - 115))
        play.close()
        play.lineJoinStyle = .round
        play.lineWidth = 46
        NSColor.white.set()
        play.fill()
        play.stroke()
        ctx.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setFill()
        sparkle(NSPoint(x: 275, y: 790), 58)
        sparkle(NSPoint(x: 760, y: 810), 34)
        sparkle(NSPoint(x: 205, y: 640), 20)
        sparkle(NSPoint(x: 830, y: 690), 22)
        color(0xFFFFFF, 0.55).setFill()
        for (x, y, s) in [(400.0, 845.0, 7.0), (620, 870, 6), (870, 560, 5), (170, 500, 6), (690, 760, 5)] {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: s, height: s)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func write(to path: String) -> Bool {
        let img = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in draw(); return true }
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
