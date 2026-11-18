import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: swift scripts/generate-icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetPath = args[1]
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderAppIcon(pixelSize: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    let s = CGFloat(pixelSize)

    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = rect.width * 0.225
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.42, green: 0.50, blue: 0.62, alpha: 1),
        CGColor(srgbRed: 0.22, green: 0.27, blue: 0.36, alpha: 1)
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: s * 0.5, y: s), end: CGPoint(x: s * 0.5, y: 0), options: [])
    ctx.restoreGState()

    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.strokePath()

    // A4 paper
    let paperW = rect.width * 0.46
    let paperH = paperW * (297.0 / 210.0)
    let paper = CGRect(x: rect.midX - paperW / 2, y: rect.midY - paperH / 2 + s * 0.01, width: paperW, height: paperH)
    let paperPath = CGPath(roundedRect: paper, cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(paperPath)
    ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Text lines
    ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.22, blue: 0.28, alpha: 0.9))
    let lineX = paper.minX + paperW * 0.16
    let lineW = paperW * 0.68
    var y = paper.maxY - paperH * 0.22
    for i in 0..<5 {
        let w = (i == 0) ? lineW * 0.55 : lineW * (i == 4 ? 0.42 : 0.92)
        let h = max(1.5, s * 0.018)
        ctx.fill(CGRect(x: lineX, y: y, width: w, height: h))
        y -= paperH * 0.12
    }

    // Folded corner
    let fold = s * 0.07
    ctx.move(to: CGPoint(x: paper.maxX, y: paper.maxY - fold))
    ctx.addLine(to: CGPoint(x: paper.maxX - fold, y: paper.maxY))
    ctx.addLine(to: CGPoint(x: paper.maxX - fold, y: paper.maxY - fold))
    ctx.closePath()
    ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.88, blue: 0.90, alpha: 1))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for (base, scale) in sizes {
    let px = base * scale
    guard let png = renderAppIcon(pixelSize: px) else { continue }
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try png.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(name))
}

print("Wrote iconset to \(iconsetPath)")
