import AppKit

/// The small-size waveform and caret from scripts/make-icon.swift, without the tile.
/// Drawing as a template keeps it sharp at any display scale and lets macOS choose
/// the foreground colour for light, dark and highlighted menu bars.
@MainActor enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            // Crop to the glyph's 582 × 520 bounds, fitting a 16 pt-high mark.
            let scale: CGFloat = 16 / 520
            context.translateBy(x: (20 - 582 * scale) / 2, y: 1)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -220, y: -252)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            let heights: [CGFloat] = [250, 460, 300]
            for (index, height) in heights.enumerated() {
                let rect = CGRect(x: 220 + CGFloat(index) * 142, y: 512 - height / 2,
                                  width: 84, height: height)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 42, cornerHeight: 42, transform: nil))
            }
            context.addPath(CGPath(roundedRect: CGRect(x: 677, y: 252, width: 70, height: 520),
                                   cornerWidth: 35, cornerHeight: 35, transform: nil))
            for y: CGFloat in [252, 712] {
                context.addPath(CGPath(roundedRect: CGRect(x: 622, y: y, width: 180, height: 60),
                                       cornerWidth: 30, cornerHeight: 30, transform: nil))
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Whispr Lite"
        return image
    }()
}
