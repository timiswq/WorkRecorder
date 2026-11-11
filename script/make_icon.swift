import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Supply an external iconset output directory") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        NSColor(srgbRed: 0.94, green: 0.96, blue: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: side * 0.08, y: side * 0.08, width: side * 0.84, height: side * 0.84), xRadius: side * 0.19, yRadius: side * 0.19).fill()
        NSColor(srgbRed: 0.20, green: 0.42, blue: 0.32, alpha: 1).setStroke()
        let heights: [CGFloat] = [0.13, 0.28, 0.45, 0.26, 0.36, 0.17]
        for (index, height) in heights.enumerated() {
            let path = NSBezierPath(); path.lineWidth = side * 0.045; path.lineCapStyle = .round
            let x = side * (0.285 + CGFloat(index) * 0.086)
            path.move(to: NSPoint(x: x, y: side * (0.5 - height / 2))); path.line(to: NSPoint(x: x, y: side * (0.5 + height / 2))); path.stroke()
        }
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try representation.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
