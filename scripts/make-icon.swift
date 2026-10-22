// Renders Resources/AppIcon.icns: a waveform running into a text caret on an
// indigo-violet tile, drawn on Apple's macOS icon grid (824 pt body on a 1024 pt
// canvas) so macOS 26 shows it as-is rather than inside a grey enclosure.
//
// Usage: swift scripts/make-icon.swift [output.icns]
import AppKit

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedBar(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil)
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    let tile = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Drop shadow from Apple's template: soft, slightly below the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.32))
    context.addPath(tile)
    context.setFillColor(color(0x3B2FB8))
    context.fillPath()
    context.restoreGState()

    // Background: diagonal indigo to violet, with a soft light from the top left.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x4338CA), color(0x6D28D9), color(0x9D3BD9)] as CFArray,
                              locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                               end: CGPoint(x: body.maxX, y: body.minY), options: [])
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF, alpha: 0.22), color(0xFFFFFF, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 820), endRadius: 620, options: [])
    context.restoreGState()

    // Hairline inner edge for definition against dark backgrounds.
    context.saveGState()
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: cornerRadius - 1.5,
                           cornerHeight: cornerRadius - 1.5, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.18))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    // Glyph: speech (waveform bars) flowing into a text caret. Six thin bars smear
    // together at 16 px, so the smallest renditions use three heavier ones.
    let small = size <= 32
    let centerY: CGFloat = 512
    let barWidth: CGFloat = small ? 84 : 46
    let gap: CGFloat = small ? 58 : 30
    let heights: [CGFloat] = small ? [250, 460, 300] : [150, 290, 430, 330, 210, 120]
    let caretX: CGFloat = small ? 712 : 728
    var x: CGFloat = caretX - (small ? 124 : 92) - CGFloat(heights.count) * (barWidth + gap) + gap
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x1E1065, alpha: 0.35))
    for (index, height) in heights.enumerated() {
        // Bars fade slightly towards the caret, as speech becomes text.
        let alpha = 1 - CGFloat(index) * 0.06
        context.addPath(roundedBar(CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)))
        context.setFillColor(color(0xFFFFFF, alpha: alpha))
        context.fillPath()
        x += barWidth + gap
    }
    // Caret: a tall rounded I-beam in a pale cyan, the "text" end of the glyph.
    let caretHeight: CGFloat = small ? 520 : 470
    let stem: CGFloat = small ? 70 : 34
    let serif = small ? CGSize(width: 180, height: 60) : CGSize(width: 118, height: 30)
    let caret = CGMutablePath()
    caret.addPath(roundedBar(CGRect(x: caretX - stem / 2, y: centerY - caretHeight / 2,
                                    width: stem, height: caretHeight)))
    for y in [centerY + caretHeight / 2 - serif.height, centerY - caretHeight / 2] {
        caret.addPath(CGPath(roundedRect: CGRect(x: caretX - serif.width / 2, y: y, width: serif.width,
                                                 height: serif.height),
                             cornerWidth: serif.height / 2, cornerHeight: serif.height / 2, transform: nil))
    }
    context.addPath(caret)
    context.setFillColor(color(0xA5F3FC))
    context.fillPath()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = render(size: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
