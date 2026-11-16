import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Supply an external iconset output directory") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/WorkdayMac/Resources/DockArtwork/CompanionNormal.png")
guard let artwork = NSImage(contentsOf: source),
      let original = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("Missing approved Dock companion artwork: \(source.path)") }
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        let side = CGFloat(pixels)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        let frame = NSRect(x: side * 0.08, y: side * 0.08, width: side * 0.84, height: side * 0.84)
        NSBezierPath(roundedRect: frame, xRadius: side * 0.19, yRadius: side * 0.19).addClip()
        context.draw(original, in: frame)
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
