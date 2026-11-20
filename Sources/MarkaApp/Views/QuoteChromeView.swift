import AppKit
import MarkaCore

/// GitHub-style quote decoration drawn behind the text: a left bar (grey; coloured for alerts) and,
/// for `> [!NOTE]`-style alerts, the icon and title on the hidden marker's line.
final class QuoteChromeView: NSView {
    var alert: MarkdownAlert.Kind?
    /// Bar and title geometry in this view's coordinates (the quote may be split across pages).
    var barRect: CGRect = .zero
    var titleRect: CGRect?
    var fontSize: CGFloat = 10
    var darkPaper = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        QuoteChromeView.draw(alert: alert, bar: barRect, title: titleRect, fontSize: fontSize, darkPaper: darkPaper)
    }

    static func color(_ alert: MarkdownAlert.Kind?, darkPaper: Bool) -> NSColor {
        func hex(_ value: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        switch alert {
        case .note?: return hex(darkPaper ? 0x4493f8 : 0x0969da)
        case .tip?: return hex(darkPaper ? 0x3fb950 : 0x1a7f37)
        case .important?: return hex(darkPaper ? 0xab7df8 : 0x8250df)
        case .warning?: return hex(darkPaper ? 0xd29922 : 0x9a6700)
        case .caution?: return hex(darkPaper ? 0xf85149 : 0xd1242f)
        case nil: return hex(darkPaper ? 0x3d444d : 0xd0d7de)
        }
    }

    /// An SF Symbol rendered into a bitmap in one colour — draws the same on screen and in PDF
    /// (palette symbol configurations print as solid squares in PDF contexts).
    static func tintedSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) else { return nil }
        let size = symbol.size
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size   // before the context: it takes its scale from rep.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: size)
        symbol.draw(in: rect)
        color.usingColorSpace(.deviceRGB)?.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func symbol(_ alert: MarkdownAlert.Kind) -> String {
        switch alert {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.bubble"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "exclamationmark.octagon"
        }
    }

    /// Shared by the view and PDF / print export.
    static func draw(alert: MarkdownAlert.Kind?, bar: CGRect, title: CGRect?, fontSize: CGFloat, darkPaper: Bool) {
        let color = self.color(alert, darkPaper: darkPaper)
        color.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        guard let alert, let title else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        var x = title.minX
        if let icon = tintedSymbol(symbol(alert), pointSize: fontSize, weight: .semibold, color: color) {
            icon.draw(in: CGRect(x: x, y: title.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += icon.size.width + fontSize * 0.5
        }
        let text = alert.title as NSString
        let size = text.size(withAttributes: [.font: font])
        text.draw(at: CGPoint(x: x, y: title.midY - size.height / 2), withAttributes: [.font: font, .foregroundColor: color])
    }
}
