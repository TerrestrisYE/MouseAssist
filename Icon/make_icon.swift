// Renders Icon/AppIcon.icns: a blue-violet rounded square with a white mouse
// between two chevrons. Run from the repo root: swift Icon/make_icon.swift

import AppKit

let iconDir = URL(fileURLWithPath: "Icon")
let iconset = iconDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Symbols are rasterized at their point size, so they must be requested at
// the final pixel size rather than drawn large and scaled down.
func symbol(_ name: String, size: CGFloat, alpha: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func draw(_ image: NSImage, centeredAt center: NSPoint) {
    let size = image.size
    image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height))
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

    draw(symbol("computermouse.fill", size: 360 * s, alpha: 1), centeredAt: NSPoint(x: 512 * s, y: 512 * s))
    draw(symbol("chevron.left", size: 120 * s, alpha: 0.75), centeredAt: NSPoint(x: (512 - 255) * s, y: 512 * s))
    draw(symbol("chevron.right", size: 120 * s, alpha: 0.75), centeredAt: NSPoint(x: (512 + 255) * s, y: 512 * s))

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
