// Draws the app icon: a white owl in simple shapes (two thick ring eyes and a diamond beak) on a black
// tile. Writes App/AppIcon.icns.
//
//     swift tools/icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Same owl as App/AgentWidgetApp.swift's menu bar icon: keep the two in step.
// The owl, in simple shapes: two thick rings for eyes, touching in the middle, and a small diamond beak.
// Grid units around 0,0 (y down): the eyes are centred at x = ±70, radius 68 with a 28 pupil hole; the beak
// sits below them. `map` turns grid points into canvas points, `k` is canvas points per unit.
// `lids`: 0 = eyes open, 1 = shut (the pupil holes close; the eyes stay round).
func drawOwl(_ map: @escaping (CGFloat, CGFloat) -> NSPoint, k: CGFloat, lids: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let R: CGFloat = 68, r: CGFloat = 28
    for cx: CGFloat in [-70, 70] {
        let c = map(cx, 0)
        NSBezierPath(ovalIn: NSRect(x: c.x - R * k, y: c.y - R * k, width: 2 * R * k, height: 2 * R * k)).fill()
        // The pupil hole; a lid comes down over it from the top, so the eye stays round and only the hole closes.
        guard lids < 1 else { continue }
        NSGraphicsContext.saveGraphicsState()
        let lid = c.y + r * k - 2 * r * k * lids
        NSRect(x: c.x - r * k, y: c.y - r * k, width: 2 * r * k, height: lid - (c.y - r * k)).clip()
        ctx.setBlendMode(.clear)
        NSBezierPath(ovalIn: NSRect(x: c.x - r * k, y: c.y - r * k, width: 2 * r * k, height: 2 * r * k)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    ctx.endTransparencyLayer()
    let beak = NSBezierPath()
    beak.move(to: map(0, 50)); beak.line(to: map(16, 74)); beak.line(to: map(0, 98)); beak.line(to: map(-16, 74)); beak.close()
    beak.fill()
}

func draw(_ s: CGFloat) {
    let tile = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 10 / 1024)
    shadow.shadowBlurRadius = s * 24 / 1024
    shadow.set()
    NSColor(white: 0.04, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    let k = tile.width * 0.68 / 276  // the eyes span 276 units across
    NSColor.white.set()
    drawOwl({ x, y in NSPoint(x: tile.midX + x * k, y: tile.midY - (y - 15) * k) }, k: k, lids: 0)
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
