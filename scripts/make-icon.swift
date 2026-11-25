// Renders the app icon: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.47, blue: 0.98, alpha: 1),
                        NSColor(red: 0.10, green: 0.78, blue: 0.70, alpha: 1)])!.draw(in: path, angle: -60)
    func symbol(_ name: String, _ pt: CGFloat, _ r: NSRect, _ alpha: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let sz = img.size
        let scale = min(r.width / sz.width, r.height / sz.height)
        let w = sz.width * scale, h = sz.height * scale
        img.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }
    symbol("arrow.triangle.2.circlepath", 400, rect.insetBy(dx: 90 * s, dy: 90 * s), 0.35)
    symbol("person.2.fill", 300, rect.insetBy(dx: 215 * s, dy: 235 * s), 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run(); p.waitUntilExit()
try! render(512).write(to: URL(fileURLWithPath: "docs/icon.png"))
print("wrote \(out)")
