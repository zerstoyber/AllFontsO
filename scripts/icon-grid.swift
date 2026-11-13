import AppKit

// Draws full-bleed artwork into the macOS icon grid: an 824 pt rounded square centred on a 1024 canvas.
// macOS 26 shrinks an icon that fills its whole canvas into a grey frame; drawn into the grid it shows full size.
// Usage: icon-grid <source.png> <out.png> [inset] [corner radius as a share of the side]
let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let inset = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 100
let radiusShare = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4])! : 0.225
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.imageInterpolation = .high
let side = 1024 - 2 * inset
let rect = CGRect(x: inset, y: inset, width: side, height: side)
let path = CGPath(roundedRect: rect, cornerWidth: side * radiusShare, cornerHeight: side * radiusShare, transform: nil)
context.cgContext.addPath(path)
context.cgContext.clip()
// A little overscan keeps the artwork's own, smaller corners outside the mask.
source.draw(in: rect.insetBy(dx: -side * 0.02, dy: -side * 0.02), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
