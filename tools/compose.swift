// Puts a demo snapshot of the panel on a generated wallpaper, blurring the wallpaper under the
// panel the way the real glass does, for the README screenshots.
//
//     swift tools/compose.swift panel.png out.png
import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count == 3, let panel = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: compose.swift panel.png out.png")
    exit(1)
}

let scale = 2.0
let pad = 56 * scale
let size = CGSize(width: Double(panel.width) + pad * 2, height: Double(panel.height) + pad * 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ alpha: Double) -> CGColor {
    CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

/// Dark navy wallpaper with a few soft colour blooms.
func wallpaper() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(rgba(0x111A2E, 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    let blooms: [(UInt32, Double, CGPoint, Double)] = [
        (0xC2410C, 0.85, CGPoint(x: 0.78, y: 0.82), 0.45),
        (0x7C3AED, 0.75, CGPoint(x: 0.12, y: 0.35), 0.5),
        (0x0E7490, 0.7, CGPoint(x: 0.85, y: 0.2), 0.4),
        (0x1D4ED8, 0.6, CGPoint(x: 0.3, y: 0.95), 0.45),
    ]
    for (hex, alpha, at, radius) in blooms {
        let gradient = CGGradient(colorsSpace: space, colors: [rgba(hex, alpha), rgba(hex, 0)] as CFArray, locations: [0, 1])!
        let center = CGPoint(x: at.x * size.width, y: at.y * size.height)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: radius * max(size.width, size.height), options: [])
    }
    return ctx.makeImage()!
}

let background = wallpaper()
let blurred = CIContext().createCGImage(
    CIImage(cgImage: background).clampedToExtent().applyingGaussianBlur(sigma: 22 * scale).cropped(to: CGRect(origin: .zero, size: size)),
    from: CGRect(origin: .zero, size: size))!

let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let full = CGRect(origin: .zero, size: size)
let frame = CGRect(x: pad, y: pad, width: Double(panel.width), height: Double(panel.height))
ctx.draw(background, in: full)
let glass = CGPath(roundedRect: frame, cornerWidth: 20 * scale, cornerHeight: 20 * scale, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 40 * scale, color: rgba(0x000000, 0.45))
ctx.addPath(glass)
ctx.setFillColor(rgba(0x000000, 1))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(glass)
ctx.clip()
ctx.draw(blurred, in: full)
ctx.restoreGState()
ctx.draw(panel, in: frame)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
