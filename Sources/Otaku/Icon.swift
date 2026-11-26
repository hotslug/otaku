import AppKit

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
        NSGradient(starting: color(0x3A1A6E), ending: color(0x120E2E))!.draw(in: tile, angle: 90)

        let sun = NSPoint(x: 512, y: 455), r: CGFloat = 255
        NSGradient(starting: color(0xFF4F8B, 0.55), ending: color(0xFF4F8B, 0))!
            .draw(fromCenter: sun, radius: r * 0.8, toCenter: sun, radius: r * 1.75, options: .drawsBeforeStartingLocation)

        let ctx = NSGraphicsContext.current!.cgContext
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let disc = NSBezierPath(ovalIn: NSRect(x: sun.x - r, y: sun.y - r, width: 2 * r, height: 2 * r))
        NSGradient(colors: [color(0xFF3D7F), color(0xFF7A59), color(0xFFD166)])!.draw(in: disc, angle: 90)
        NSGraphicsContext.current!.compositingOperation = .destinationOut
        for (dy, h) in [(-30.0, 9.0), (-85, 15), (-140, 22), (-195, 30)] {
            NSRect(x: sun.x - r, y: sun.y + dy - h / 2, width: 2 * r, height: h).fill()
        }
        ctx.endTransparencyLayer()

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color(0x7A1E52, 0.6)
        glow.shadowBlurRadius = 30
        glow.shadowOffset = NSSize(width: 0, height: -8)
        glow.set()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
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

    static func writeDMGBackground(to dir: String) -> Bool {
        [1, 2].allSatisfy { scale in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 660 * scale, pixelsHigh: 400 * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 660, height: 400)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            drawDMGBackground()
            NSGraphicsContext.restoreGraphicsState()
            let file = dir + (scale == 1 ? "/bg.png" : "/bg@2x.png")
            return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))) != nil
        }
    }

    static func drawDMGBackground() {
        let w: CGFloat = 660, h: CGFloat = 400
        NSGradient(starting: color(0xFFFFFF), ending: color(0xF6C9DF))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

        let sun = NSImage(size: NSSize(width: 300, height: 100), flipped: false) { _ in
            let disc = NSBezierPath(ovalIn: NSRect(x: 0, y: -205, width: 300, height: 300))
            disc.addClip()
            NSGradient(colors: [color(0xFF3D7F), color(0xFF7A59), color(0xFFD166)])!.draw(in: NSRect(x: 0, y: 0, width: 300, height: 95), angle: 90)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for (y, t) in [(10.0, 7.0), (31, 6), (50, 5), (67, 4), (81, 3)] { NSRect(x: 0, y: y, width: 300, height: t).fill() }
            return true
        }
        sun.draw(in: NSRect(x: w / 2 - 150, y: 0, width: 300, height: 100), from: .zero, operation: .sourceOver, fraction: 0.85)

        for (x, y, r, c) in [(70.0, 330.0, 14.0, 0xFF3D7F), (600, 345, 11, 0xE8A317), (105, 80, 10, 0xE8A317), (565, 95, 13, 0xFF7A59), (575, 300, 6, 0xFF3D7F), (60, 200, 6, 0xFF7A59)] {
            color(c, 0.8).setFill(); sparkle(NSPoint(x: x, y: y), r)
        }

        let y = h - 190
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 262, y: y + 4))
        arrow.curve(to: NSPoint(x: 392, y: y + 4), controlPoint1: NSPoint(x: 300, y: y + 30), controlPoint2: NSPoint(x: 354, y: y + 30))
        arrow.lineWidth = 6; arrow.lineCapStyle = .round
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 376, y: y + 22)); head.line(to: NSPoint(x: 396, y: y + 2)); head.line(to: NSPoint(x: 370, y: y - 4))
        head.lineWidth = 6; head.lineCapStyle = .round; head.lineJoinStyle = .round
        color(0xFF5A6C).setStroke()
        arrow.stroke(); head.stroke()

        let text = NSAttributedString(string: "Drag Otaku into Applications to install", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: color(0x2A1657)])
        text.draw(at: NSPoint(x: (w - text.size().width) / 2, y: h - 62))
    }
}
