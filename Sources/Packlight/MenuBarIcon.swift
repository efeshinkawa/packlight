import AppKit

/// The Packlight mark: a small travel pack whose pocket doubles as a charge bar.
/// Drawn from plain paths (no SF Symbols — Apple's license doesn't allow them in icons or logos).
enum PacklightMark {
    /// Draws the pack into `r`. `fill` sets how much of the charge pocket is filled (0...1);
    /// `solid` fills the pack body instead of outlining it.
    static func draw(in r: NSRect, color: NSColor, solid: Bool, fill: CGFloat, pocketColor: NSColor? = nil) {
        let u = r.width
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: r.minX + x * u, y: r.minY + y * u, width: w * u, height: h * u)
        }
        let line = max(1.4, u * 0.085)
        color.set()

        // Carry loop: small and low, so the shape reads as a bag rather than a padlock.
        let handle = NSBezierPath(roundedRect: rect(0.38, 0.62, 0.24, 0.24), xRadius: 0.09 * u, yRadius: 0.09 * u)
        handle.lineWidth = line
        handle.stroke()

        // Body: wider than tall.
        let body = NSBezierPath(roundedRect: rect(0.06, 0.06, 0.88, 0.62), xRadius: 0.18 * u, yRadius: 0.18 * u)
        // Pocket: a battery (with its terminal nub) whose fill is the charge.
        let pocket = rect(0.22, 0.17, 0.48, 0.20)
        let cell = NSBezierPath(roundedRect: pocket, xRadius: 0.06 * u, yRadius: 0.06 * u)
        let nub = NSBezierPath(roundedRect: rect(0.70, 0.22, 0.06, 0.10), xRadius: 0.02 * u, yRadius: 0.02 * u)
        // Flap seam across the top of the body.
        let flap = NSBezierPath()
        flap.move(to: NSPoint(x: r.minX + 0.16 * u, y: r.minY + 0.50 * u))
        flap.curve(to: NSPoint(x: r.minX + 0.84 * u, y: r.minY + 0.50 * u),
                   controlPoint1: NSPoint(x: r.minX + 0.38 * u, y: r.minY + 0.42 * u),
                   controlPoint2: NSPoint(x: r.minX + 0.62 * u, y: r.minY + 0.42 * u))
        flap.lineWidth = line * 0.7
        flap.lineCapStyle = .round

        var filled = pocket.insetBy(dx: 0.055 * u, dy: 0.055 * u)
        filled.size.width *= max(0, min(1, fill))
        let charge = NSBezierPath(roundedRect: filled, xRadius: 0.03 * u, yRadius: 0.03 * u)

        if solid {
            body.fill()
            // Knock the seam and the battery out of the solid body so they read at 16 px.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            flap.stroke()
            cell.fill()
            nub.fill()
            // Refill inside the battery, leaving a thin ring as its outline.
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            let ring = max(1, 0.03 * u)
            NSBezierPath(roundedRect: pocket.insetBy(dx: ring, dy: ring), xRadius: 0.04 * u, yRadius: 0.04 * u).fill()
            if let pocketColor {
                pocketColor.set()
                charge.fill()
            } else {
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                charge.fill()
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            }
        } else {
            body.lineWidth = line
            body.stroke()
            flap.stroke()
            cell.lineWidth = line * 0.7
            cell.stroke()
            nub.fill()
            charge.fill()
        }
    }

    /// Full-color app icon: the white pack on a green squircle.
    static func appIcon(size: CGFloat) -> NSBitmapImageRep {
        let px = Int(size)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        // macOS icon grid: ~10% margin around the squircle.
        let tile = canvas.insetBy(dx: size * 0.1, dy: size * 0.1)
        let squircle = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(colors: [NSColor(red: 0.27, green: 0.82, blue: 0.52, alpha: 1),
                            NSColor(red: 0.04, green: 0.47, blue: 0.40, alpha: 1)])!
            .draw(in: squircle, angle: -70)
        let mark = tile.insetBy(dx: tile.width * 0.2, dy: tile.width * 0.2)
        let pocketGreen = NSColor(red: 0.20, green: 0.74, blue: 0.47, alpha: 1)
        // Own layer, so knock-outs reveal the green tile instead of punching through it.
        let cg = NSGraphicsContext.current!.cgContext
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(in: mark, color: .white, solid: true, fill: 0.72, pocketColor: pocketGreen)
        cg.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

enum MenuBarIcon {
    /// Template image for the menu bar: solid pack at Home, outlined (light) pack when Away.
    static func image(mode: Mode, busy: Bool, pending: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { r in
            let home = mode == .home
            PacklightMark.draw(in: r.insetBy(dx: 1, dy: 1), color: .black, solid: home,
                               fill: busy ? 0.5 : (home ? 1 : 0.3))
            if pending {
                // A small dot: unplugged, Away countdown running.
                NSColor.black.set()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 5, height: 5)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
