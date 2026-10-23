// Draws the app icon: a dark glass tile with the panel's corner glow and a green ticket,
// the same ticket as the menu bar icon. Writes App/AppIcon.icns.
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

    // The ticket, as in the menu bar, in Payhawk green.
    let w = s * 520 / 1024, h = s * 370 / 1024
    let r = NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
    let corner = s * 64 / 1024, notch = s * 62 / 1024
    let ticket = NSBezierPath()
    ticket.move(to: NSPoint(x: r.minX + corner, y: r.minY))
    ticket.line(to: NSPoint(x: r.maxX - corner, y: r.minY))
    ticket.appendArc(withCenter: NSPoint(x: r.maxX - corner, y: r.minY + corner), radius: corner, startAngle: 270, endAngle: 360)
    ticket.line(to: NSPoint(x: r.maxX, y: r.midY - notch))
    ticket.appendArc(withCenter: NSPoint(x: r.maxX, y: r.midY), radius: notch, startAngle: 270, endAngle: 90, clockwise: true)
    ticket.line(to: NSPoint(x: r.maxX, y: r.maxY - corner))
    ticket.appendArc(withCenter: NSPoint(x: r.maxX - corner, y: r.maxY - corner), radius: corner, startAngle: 0, endAngle: 90)
    ticket.line(to: NSPoint(x: r.minX + corner, y: r.maxY))
    ticket.appendArc(withCenter: NSPoint(x: r.minX + corner, y: r.maxY - corner), radius: corner, startAngle: 90, endAngle: 180)
    ticket.line(to: NSPoint(x: r.minX, y: r.midY + notch))
    ticket.appendArc(withCenter: NSPoint(x: r.minX, y: r.midY), radius: notch, startAngle: 90, endAngle: 270, clockwise: true)
    ticket.line(to: NSPoint(x: r.minX, y: r.minY + corner))
    ticket.appendArc(withCenter: NSPoint(x: r.minX + corner, y: r.minY + corner), radius: corner, startAngle: 180, endAngle: 270)
    ticket.close()
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x3DDC84, 0.6)
    glow.shadowBlurRadius = s * 40 / 1024
    glow.set()
    ticket.lineWidth = s * 40 / 1024
    ticket.lineJoinStyle = .round
    color(0x3DDC84).setStroke()
    ticket.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let tear = NSBezierPath()
    tear.move(to: NSPoint(x: r.minX + w * 0.62, y: r.minY + h * 0.22))
    tear.line(to: NSPoint(x: r.minX + w * 0.62, y: r.maxY - h * 0.22))
    tear.lineWidth = s * 40 / 1024
    tear.lineCapStyle = .round
    let dash = h * 0.56 / 3.4
    tear.setLineDash([dash * 0.6, dash * 1.6], count: 2, phase: -dash * 0.2)
    color(0x3DDC84).setStroke()
    tear.stroke()
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
