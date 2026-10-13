import AppKit

let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(srgbRed: 0.070, green: 0.060, blue: 0.090, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88), xRadius: size * 0.20, yRadius: size * 0.20).fill()
    let amber = NSColor(srgbRed: 0.925, green: 0.710, blue: 0.400, alpha: 1)
    let center = NSPoint(x: size * 0.5, y: size * 0.53)
    let radius = size * 0.28
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: -45, endAngle: 225)
    amber.setStroke(); arc.lineWidth = size * 0.038; arc.lineCapStyle = .round; arc.stroke()
    let hand = NSBezierPath(); hand.move(to: center)
    hand.line(to: NSPoint(x: center.x + size * 0.16, y: center.y + size * 0.16))
    hand.lineWidth = size * 0.04; hand.lineCapStyle = .round; hand.stroke()
    amber.setFill(); NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.03, y: center.y - size * 0.03, width: size * 0.06, height: size * 0.06)).fill()
    for i in 0..<3 {
        amber.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: size * (0.37 + Double(i) * 0.09), y: size * 0.20, width: size * 0.08, height: size * 0.04), xRadius: size * 0.012, yRadius: size * 0.012).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch pixels {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
}
