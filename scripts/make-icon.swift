// Renders the Nexus app icon (gradient squircle + hexagon grid glyph) into an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
for (px, name) in sizes {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.12, blue: 0.22, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)])!.draw(in: path, angle: -90)
    path.addClip()
    NSGradient(colors: [NSColor(red: 0.49, green: 0.42, blue: 1, alpha: 0.55), .clear])!.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), relativeCenterPosition: NSPoint(x: 0.6, y: 0.8))
    if let sym = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: s * 0.42, weight: .semibold).applying(.init(paletteColors: [NSColor(red: 0.45, green: 0.8, blue: 1, alpha: 1)]))) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
