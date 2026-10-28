// Renders Icon/AppIcon.icns: a blue-violet rounded square with a white mouse
// between two chevrons. Run from the repo root: swift Icon/make_icon.swift

import AppKit

let iconDir = URL(fileURLWithPath: "Icon")
let iconset = iconDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Everything is drawn with plain paths (no SF Symbols, which Apple's license
// does not allow in app icons).
func chevron(pointingLeft: Bool, at center: NSPoint, s: CGFloat) {
    let dx = (pointingLeft ? 30 : -30) * s
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x + dx, y: center.y + 60 * s))
    path.line(to: NSPoint(x: center.x - dx, y: center.y))
    path.line(to: NSPoint(x: center.x + dx, y: center.y - 60 * s))
    path.lineWidth = 24 * s
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.75).setStroke()
    path.stroke()
}

// A white mouse seen from above: a stadium-shaped body, the line between the
// two buttons, and a scroll wheel, the details cut in the background color.
func mouse(centeredAt center: NSPoint, s: CGFloat, detail: NSColor) {
    let body = NSRect(x: center.x - 115 * s, y: center.y - 180 * s, width: 230 * s, height: 360 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 115 * s, yRadius: 115 * s)
    NSColor.white.setFill()
    shape.fill()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let split = body.maxY - 140 * s
    let lines = NSBezierPath()
    lines.move(to: NSPoint(x: center.x, y: body.maxY))
    lines.line(to: NSPoint(x: center.x, y: split))
    lines.move(to: NSPoint(x: body.minX, y: split))
    lines.line(to: NSPoint(x: body.maxX, y: split))
    lines.lineWidth = 12 * s
    detail.setStroke()
    lines.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let wheel = NSRect(x: center.x - 15 * s, y: split + 30 * s, width: 30 * s, height: 66 * s)
    detail.setFill()
    NSBezierPath(roundedRect: wheel, xRadius: 15 * s, yRadius: 15 * s).fill()
}

// The layout follows the macOS icon grid on a 1024 canvas (824 body, 100
// margin); `s` maps it to each output size, drawn one point per pixel.
func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let s = CGFloat(pixels) / 1024
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let body = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    let top = NSColor(srgbRed: 0.36, green: 0.60, blue: 1.00, alpha: 1)
    let bottom = NSColor(srgbRed: 0.42, green: 0.27, blue: 0.92, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: body, angle: -90)

    mouse(centeredAt: NSPoint(x: 512 * s, y: 512 * s), s: s, detail: bottom.blended(withFraction: 0.5, of: top)!)
    chevron(pointingLeft: true, at: NSPoint(x: (512 - 255) * s, y: 512 * s), s: s)
    chevron(pointingLeft: false, at: NSPoint(x: (512 + 255) * s, y: 512 * s), s: s)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", iconDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote Icon/AppIcon.icns" : "iconutil failed")
