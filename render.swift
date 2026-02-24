import Cocoa
let args = CommandLine.arguments
let inputUrl = URL(fileURLWithPath: args[1])
let outputUrl = URL(fileURLWithPath: args[2])
let size = Double(args[3])!
guard let image = NSImage(contentsOf: inputUrl) else { exit(1) }
let targetSize = NSSize(width: size, height: size)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.size = targetSize
image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
guard let pngData = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! pngData.write(to: outputUrl)
