// Makes the app icon from RPCS3's own logo (rpcs3/rpcs3/rpcs3.svg in the submodule):
//   swift scripts/gen-app-icon.swift
// iOS wants a square, opaque 1024x1024 image and rounds the corners itself, so the logo's rounded
// square is scaled to fill the icon over the logo's own gradient.

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svg = root.appending(path: "rpcs3/rpcs3/rpcs3.svg")
let output = root.appending(path: "app/rpcs3/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

guard let logo = NSImage(contentsOf: svg) else { fatalError("Cannot read \(svg.path)") }

func render(_ size: Int, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

// Where the logo's rounded square is: the bounds of what it draws
let probeSize = 2048
let probe = render(probeSize, opaque: false) { _ in
    logo.draw(in: NSRect(x: 0, y: 0, width: probeSize, height: probeSize))
}
let data = CFDataGetBytePtr(probe.dataProvider!.data)!
var (minX, minY, maxX, maxY) = (probeSize, probeSize, 0, 0)
for y in 0..<probeSize {
    for x in 0..<probeSize where data[y * probe.bytesPerRow + x * 4 + 3] > 128 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let side = Double(max(maxX - minX, maxY - minY) + 1) / Double(probeSize)
let left = Double(minX) / Double(probeSize), top = Double(minY) / Double(probeSize)
print("logo square: \(minX)...\(maxX) x \(minY)...\(maxY) of \(probeSize)")

let size = 1024
let icon = render(size, opaque: true) { _ in
    // The logo's gradient, light at the top
    let gradient = NSGradient(starting: NSColor(srgbRed: 0x7d / 255, green: 0x69 / 255, blue: 0xc6 / 255, alpha: 1),
                              ending: NSColor(srgbRed: 0x4f / 255, green: 0x34 / 255, blue: 0xc9 / 255, alpha: 1))!
    gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
    // The logo, its rounded square stretched to the icon's edges
    let scale = Double(size) / side
    // Image rows run from the top; drawing coordinates from the bottom
    let bottom = 1 - top - side
    logo.draw(in: NSRect(x: -left * scale, y: -bottom * scale, width: scale, height: scale))
}

let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:])!
try png.write(to: output)
print("wrote \(output.path)")
