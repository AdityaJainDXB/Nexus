import AppKit
let out = CommandLine.arguments[1]
let W: CGFloat = 660, H: CGFloat = 420
for scale in [1, 2] {
    let s = CGFloat(scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*s), pixelsHigh: Int(H*s), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(red: 0.027, green: 0.039, blue: 0.07, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    let cyan = NSColor(red: 0.22, green: 0.886, blue: 1, alpha: 1)
    cyan.withAlphaComponent(0.07).setStroke()
    let grid = NSBezierPath(); grid.lineWidth = 0.5
    for x in stride(from: 0, through: W, by: 22) { grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: H)) }
    for y in stride(from: 0, through: H, by: 22) { grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: W, y: y)) }
    grid.stroke()
    NSGradient(colors: [cyan.withAlphaComponent(0.22), .clear])!.draw(in: NSBezierPath(ovalIn: NSRect(x: 380, y: 180, width: 420, height: 380)), relativeCenterPosition: .zero)
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: cyan, .kern: 3]
    ("NEXUS // INSTALL" as NSString).draw(at: NSPoint(x: 32, y: H - 44), withAttributes: title)
    let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
    ("Drag Nexus into Applications" as NSString).draw(at: NSPoint(x: 32, y: H - 70), withAttributes: sub)
    // arrow between icon slots (icons at x=170 and x=490, y≈210 from top)
    let arrow = NSBezierPath(); arrow.lineWidth = 3; arrow.lineCapStyle = .round
    arrow.move(to: NSPoint(x: 262, y: 205)); arrow.line(to: NSPoint(x: 398, y: 205))
    arrow.move(to: NSPoint(x: 382, y: 219)); arrow.line(to: NSPoint(x: 400, y: 205)); arrow.line(to: NSPoint(x: 382, y: 191))
    NSGradient(colors: [cyan, NSColor(red: 0.56, green: 0.49, blue: 1, alpha: 1)])!.draw(in: NSRect(x: 255, y: 185, width: 150, height: 40), angle: 0)
    NSColor(red: 0.027, green: 0.039, blue: 0.07, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 255, y: 185, width: 150, height: 40)).fill()
    cyan.setStroke(); arrow.stroke()
    let foot: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
    ("On first launch: right-click Nexus → Open (or System Settings → Privacy & Security → Open Anyway)" as NSString).draw(at: NSPoint(x: 32, y: 26), withAttributes: foot)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: scale == 1 ? out : out.replacingOccurrences(of: ".png", with: "@2x.png")))
}
