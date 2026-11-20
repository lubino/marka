import AppKit
import CoreText

// Marka app icon — a single vector source.
//
//   swift scripts/generate-icon.swift <out.iconset> [--icon <AppIcon.icon>] [--preview <file.png>]
//
// * `<out.iconset>`: flat PNGs for `iconutil` → AppIcon.icns (CFBundleIconFile, pre-macOS 26 fallback).
// * `--icon`: (re)writes the committed Icon Composer bundle Resources/AppIcon.icon, which `actool`
//   compiles into a Liquid Glass Assets.car on macOS 26+.
// * `--preview`: a 1024 px PNG of the flat render.
//
// Design: a thick rounded slab of clear glass — bright rim, a diagonal reflection, a soft
// caustic at the bottom. On it, flat and crisp (no shadow, no gloss, so it stays sharp when
// small): a big "Marka" in Arial Bold across the top, two full-width bars, then two shorter bars
// on the left with "MD" beside them at the bottom right. Solid #505E76.
// Geometry: 1024 × 1024 canvas, y down.

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: swift scripts/generate-icon.swift <output.iconset> [--icon <AppIcon.icon>] [--preview <file.png>]\n", stderr)
    exit(1)
}
func argument(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}
let iconsetPath = args[1]
let iconBundlePath = argument("--icon")
let previewPath = argument("--preview")

/// The words on the slab.
let wordmark = "Marka"
let suffix = "MD"

// MARK: - Palette

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    var svg: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    func iconJSON(_ alpha: CGFloat = 1) -> String { String(format: "extended-srgb:%.5f,%.5f,%.5f,%.5f", r, g, b, alpha) }
}

let slate = RGB(0x505E76)        // text and bars
let slateDeep = RGB(0x3A4558)    // lower edge of the raised shapes
let glassTop = RGB(0xF7F9FC)
let glassBottom = RGB(0xD9DFE7)
let rimDark = RGB(0x8F9BAB)

// MARK: - Geometry (1024 canvas, y down; content placed as on the reference slab)

let canvas: CGFloat = 1024
let left: CGFloat = 127
let right: CGFloat = 897
let barHeight: CGFloat = 50

/// Arial Bold (the design's font; the system bold if Arial is missing).
let iconFont = NSFont(name: "Arial-BoldMT", size: 200) ?? NSFont.systemFont(ofSize: 200, weight: .bold)

/// `text` as glyph outlines in y-up glyph space (no font needed at runtime).
func glyphOutlines(_ string: String, kern: CGFloat = 0) -> CGPath {
    let text = NSAttributedString(string: string, attributes: [.font: iconFont, .kern: kern])
    let line = CTLineCreateWithAttributedString(text)
    let glyphs = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let font = attributes[kCTFontAttributeName] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var ids = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for i in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(font, ids[i], nil) else { continue }
            glyphs.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
        }
    }
    return glyphs
}

/// Places y-up glyph outlines so their ink fills `box` (y down): `fitWidth` scales the ink to the
/// box's width (top-aligned), otherwise to its height (right-aligned).
func place(_ glyphs: CGPath, in box: CGRect, fitWidth: Bool) -> CGPath {
    let ink = glyphs.boundingBoxOfPath
    let scale = fitWidth ? box.width / ink.width : box.height / ink.height
    let x = fitWidth ? box.minX : box.maxX - ink.width * scale
    // Ink top (glyph maxY) goes to box.minY.
    var t = CGAffineTransform(translationX: x, y: box.minY)
    t = t.scaledBy(x: scale, y: -scale)
    t = t.translatedBy(x: -ink.minX, y: -ink.maxY)
    return glyphs.copy(using: &t) ?? glyphs
}

/// Bar rows (centres): two full-width, then two short ones beside "MD".
let barRows: [CGFloat] = [500, 594, 708, 812]
let shortBarEnd: CGFloat = 470

/// "Marka" across the top and "MD" at the bottom right, as one shape.
func wordmarkPath() -> CGPath {
    let path = CGMutablePath()
    path.addPath(place(glyphOutlines(wordmark, kern: -2), in: CGRect(x: left, y: 190, width: right - left, height: 0), fitWidth: true))
    // "MD": exactly as tall as the two short bars it sits beside.
    let top = barRows[2] - barHeight / 2, bottom = barRows[3] + barHeight / 2
    path.addPath(place(glyphOutlines(suffix), in: CGRect(x: shortBarEnd + 40, y: top, width: right - shortBarEnd - 40, height: bottom - top), fitWidth: false))
    return path
}

struct Bar {
    var x0: CGFloat, x1: CGFloat, centerY: CGFloat
    var height: CGFloat = barHeight
    var clearGlass = false
    var rect: CGRect { CGRect(x: x0, y: centerY - height / 2, width: x1 - x0, height: height) }
    var path: CGPath { CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil) }
}

/// Few, thick bars: two full lines of text, then two shorter ones next to "MD".
let bars: [Bar] = [
    Bar(x0: left, x1: right, centerY: barRows[0]),
    Bar(x0: left, x1: right, centerY: barRows[1]),
    Bar(x0: left, x1: shortBarEnd, centerY: barRows[2]),
    Bar(x0: left, x1: shortBarEnd, centerY: barRows[3])
]

func combined(_ paths: [CGPath]) -> CGPath {
    let p = CGMutablePath()
    paths.forEach { p.addPath($0) }
    return p
}

let solidBars = combined(bars.filter { !$0.clearGlass }.map(\.path))
let wordmarkShape = wordmarkPath()

// MARK: - Flat render (preview PNG + .icns fallback)

func render(pixelSize: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let px = CGFloat(pixelSize) / canvas
    ctx.translateBy(x: 0, y: CGFloat(pixelSize))
    ctx.scaleBy(x: px, y: -px)
    let space = CGColorSpaceCreateDeviceRGB()
    func gradient(_ colors: [CGColor], _ locations: [CGFloat] = [0, 1]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }

    // macOS icon grid: 824 pt slab, 100 pt margin.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 185.4
    let slab = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let rimWidth: CGFloat = 16
    let inner = body.insetBy(dx: rimWidth, dy: rimWidth)
    let innerPath = CGPath(roundedRect: inner, cornerWidth: radius - rimWidth, cornerHeight: radius - rimWidth, transform: nil)

    // Shadow on the "table" under the glass.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * px), blur: 42 * px, color: CGColor(gray: 0.1, alpha: 0.22))
    ctx.addPath(slab)
    ctx.setFillColor(glassBottom.cg(1))
    ctx.fillPath()
    ctx.restoreGState()

    // Glass body, painted OPAQUE: macOS 26 only uses a flat .icns as the icon's own plate when it
    // is a solid rounded square on the standard grid. A translucent slab is treated as
    // non-conforming and placed onto a second, system-drawn plate ("two glasses").
    ctx.saveGState()
    ctx.addPath(slab)
    ctx.clip()
    ctx.drawLinearGradient(gradient([glassTop.cg(1), glassBottom.cg(1)]), start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    // Soft caustic where light focuses through the slab.
    ctx.drawRadialGradient(gradient([CGColor(srgbRed: 1, green: 0.97, blue: 0.93, alpha: 0.45), CGColor(gray: 1, alpha: 0)]),
                           startCenter: CGPoint(x: 560, y: 820), startRadius: 0, endCenter: CGPoint(x: 560, y: 820), endRadius: 300, options: [])
    ctx.restoreGState()

    // Thick rim: bright at the top-left, cooler at the bottom-right.
    ctx.saveGState()
    let ring = CGMutablePath()
    ring.addPath(slab)
    ring.addPath(innerPath)
    ctx.addPath(ring)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0.95), rimDark.cg(0.55), CGColor(gray: 1, alpha: 0.75)], [0, 0.65, 1]),
                           start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(innerPath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(rimDark.cg(0.55))
    ctx.setLineWidth(1.5)
    ctx.strokePath()

    // Content sits inside the glass: map the 1024 design onto the slab.
    ctx.saveGState()
    ctx.translateBy(x: body.minX, y: body.minY)
    ctx.scaleBy(x: body.width / canvas, y: body.height / canvas)

    /// Flat solid slate — crisp at every size (no shadow, no gloss).
    func shiny(_ path: CGPath, perShape rects: [CGRect], edgeHighlight: Bool) {
        ctx.setShouldAntialias(true)
        ctx.addPath(path)
        ctx.setFillColor(slate.cg())
        ctx.fillPath()
    }
    shiny(wordmarkShape, perShape: [wordmarkShape.boundingBoxOfPath], edgeHighlight: false)
    shiny(solidBars, perShape: bars.filter { !$0.clearGlass }.map(\.rect), edgeHighlight: true)

    ctx.restoreGState()

    // Diagonal reflection across the face of the slab.
    ctx.saveGState()
    ctx.addPath(innerPath)
    ctx.clip()
    let band = CGMutablePath()
    band.move(to: CGPoint(x: body.minX, y: body.minY + 120))
    band.addLine(to: CGPoint(x: body.minX + 300, y: body.minY))
    band.addLine(to: CGPoint(x: body.maxX, y: body.minY))
    band.addLine(to: CGPoint(x: body.maxX, y: body.minY + 120))
    band.addLine(to: CGPoint(x: body.minX, y: body.minY + 470))
    band.closeSubpath()
    ctx.addPath(band)
    ctx.clip()
    ctx.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0.32), CGColor(gray: 1, alpha: 0.04)]),
                           start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.minX + 260, y: body.minY + 430), options: [])
    ctx.restoreGState()
    return rep
}

// MARK: - Icon Composer bundle (Liquid Glass on macOS 26+)

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let pts = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(f(pts[0].x)) \(f(pts[0].y))"
        case .addLineToPoint: d += "L\(f(pts[0].x)) \(f(pts[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y))"
        case .addCurveToPoint:
            d += "C\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y)) \(f(pts[2].x)) \(f(pts[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func writeIconBundle(at path: String) throws {
    let fm = FileManager.default
    let assets = URL(fileURLWithPath: path).appendingPathComponent("Assets")
    try? fm.removeItem(atPath: path)
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    let layers: [(name: String, path: CGPath, color: String)] = [
        ("wordmark", wordmarkShape, slate.svg),
        ("bars", solidBars, slate.svg)
    ]
    for layer in layers {
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <path fill="\(layer.color)" d="\(svgPathData(layer.path))"/>
        </svg>

        """
        try svg.write(to: assets.appendingPathComponent("\(layer.name).svg"), atomically: true, encoding: .utf8)
    }
    // The icon's own glass is the slab (light fill). Wordmark and bars: glass lighting but opaque
    // (translucency off) — "shiny, not translucent". Accent bars: real translucent glass.
    func group(_ name: String, _ layer: String, translucent: Bool, opacity: Double) -> String {
        """
            {
              "name" : "\(name)",
              "lighting" : "individual",
              "specular" : false,
              "shadow" : { "kind" : "none", "opacity" : 0 },
              "translucency" : { "enabled" : \(translucent), "value" : 0.5 },
              "layers" : [
                { "name" : "\(layer)", "image-name" : "\(layer).svg", "glass" : false, "opacity" : \(opacity) }
              ]
            }
        """
    }
    let json = """
    {
      "fill" : {
        "linear-gradient" : [
          "\(glassTop.iconJSON())",
          "\(glassBottom.iconJSON())"
        ]
      },
      "groups" : [
    \(group("Wordmark", "wordmark", translucent: false, opacity: 1)),
    \(group("Bars", "bars", translucent: false, opacity: 1))
      ],
      "supported-platforms" : {
        "squares" : "shared"
      }
    }

    """
    try json.write(toFile: (path as NSString).appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("Wrote Icon Composer bundle to \(path)")
}

// MARK: - Main

try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (base, scale) in sizes {
    guard let png = render(pixelSize: base * scale).representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try png.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(name))
}
print("Wrote iconset to \(iconsetPath)")
if let previewPath, let png = render(pixelSize: 1024).representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: previewPath))
    print("Wrote preview to \(previewPath)")
}
if let iconBundlePath {
    try writeIconBundle(at: iconBundlePath)
}
