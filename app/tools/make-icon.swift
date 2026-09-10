// Generates the app icon from the same SF Symbol the UI uses, so the Dock icon
// and the in-window mark stay identical. Run from the app directory:
//
//   swift tools/make-icon.swift Resources/icon-1024.png
//   iconutil -c icns -o Resources/CodexGatewayApp.icns <iconset>
//
// The 1024px PNG is the source of truth; CodexGatewayApp.icns is checked in so
// a normal build does not need this script.

import AppKit

let symbolName = "point.3.connected.trianglepath.dotted"
let px = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)

// Teal squircle background, matching the accent color used in the window.
let margin: CGFloat = 100
let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let radius = rect.width * 0.235
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [NSColor(srgbRed: 38/255, green: 178/255, blue: 168/255, alpha: 1),
                    NSColor(srgbRed: 16/255, green: 84/255, blue: 116/255, alpha: 1)])!
    .draw(in: squircle, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// White SF Symbol. Palette color and point size must go into one configuration:
// chaining withSymbolConfiguration drops the palette and yields a black glyph.
let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!
var config = NSImage.SymbolConfiguration(pointSize: 700, weight: .medium)
config = config.applying(.init(paletteColors: [.white]))
let glyph = symbol.withSymbolConfiguration(config)!

let glyphSize = glyph.size
let scale = 880.0 / max(glyphSize.width, glyphSize.height)
let drawSize = NSSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
glyph.draw(in: NSRect(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2,
                      width: drawSize.width, height: drawSize.height),
           from: NSRect(origin: .zero, size: glyphSize),
           operation: .sourceOver, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
