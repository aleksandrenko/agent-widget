// Draws the app icon: a dark glass tile with the panel's corner glow and minimal green binoculars
// (BirdWatcher). Writes App/AppIcon.icns.
//
//     swift tools/icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(_ s: CGFloat) {
    // macOS icon grid: the tile is 824/1024 of the canvas, corner radius 185/1024.
    let tile = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 10 / 1024)
    shadow.shadowBlurRadius = s * 24 / 1024
    shadow.set()
    color(0x0B1222).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x16213B), color(0x080D1A)])!.draw(in: tile, angle: -90)
    // The panel's corner glow: blue in the top-left corner, violet to the right, teal below.
    for (hex, alpha, x, y, r) in [(0x3B82F6, 0.75, 0.0, 1.0, 0.75), (0x8B5CF6, 0.5, 0.55, 0.95, 0.5), (0x14B8A6, 0.4, 0.05, 0.55, 0.5)] as [(UInt32, CGFloat, CGFloat, CGFloat, CGFloat)] {
        let center = NSPoint(x: tile.minX + tile.width * x, y: tile.minY + tile.height * y)
        NSGradient(colors: [color(hex, alpha), color(hex, 0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: tile.width * r, options: [])
    }
    // A glass rim.
    color(0xFFFFFF, 0.18).setStroke()
    shape.lineWidth = s * 6 / 1024
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Binoculars, the minimal way: two thick rings, a bridge and two eyepiece ticks, in Payhawk green.
    // Drawn on a 64-unit grid (y up), centred on the tile.
    let u = s * 11.7 / 1024
    let p = { (x: CGFloat, y: CGFloat) in NSPoint(x: s / 2 + (x - 32) * u, y: s / 2 + (35 - y) * u) }  // the rings carry the weight: centre on them
    let green = color(0x3DDC84)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x3DDC84, 0.6)
    glow.shadowBlurRadius = s * 40 / 1024
    glow.set()
    green.setStroke()
    for cx: CGFloat in [19, 45] {
        let c = p(cx, 38)
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 11 * u, y: c.y - 11 * u, width: 22 * u, height: 22 * u))
        ring.lineWidth = 5.5 * u
        ring.stroke()
    }
    let lines = NSBezierPath()
    lines.move(to: p(30, 34)); lines.line(to: p(34, 34))
    lines.move(to: p(14, 22)); lines.line(to: p(17, 16))
    lines.move(to: p(50, 22)); lines.line(to: p(47, 16))
    lines.lineWidth = 5 * u
    lines.lineCapStyle = .round
    lines.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

for size in sizes {
    for scale in [1, 2] where size * scale <= 1024 && !(size == 1024 && scale == 1) || (size == 1024 && scale == 1) {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGFloat(px))
        NSGraphicsContext.restoreGraphicsState()
        let name = size == 1024 ? "icon_512x512@2x.png" : scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        if size == 1024 && scale == 2 { continue }
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
print(out.path)
