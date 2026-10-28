import Cocoa

// 生成 1024x1024（精确像素）的 app 图标 PNG
let px = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("无法创建位图\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 圆角底板 + 渐变
let size = CGFloat(px)
let inset: CGFloat = 44
let path = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
                        xRadius: 200, yRadius: 200)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.30, green: 0.50, blue: 0.98, alpha: 1.0),
    NSColor(srgbRed: 0.11, green: 0.21, blue: 0.58, alpha: 1.0)
])!
gradient.draw(in: path, angle: -90)

// 摄像头符号（白色）
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = symbol.size
    let target = NSRect(x: (size - s.width) / 2,
                        y: (size - s.height) / 2,
                        width: s.width,
                        height: s.height)
    symbol.draw(in: target)
}
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("编码失败\n".data(using: .utf8)!)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)")
