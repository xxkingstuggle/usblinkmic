import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Input is a full-bleed square master, without an embedded rounded tile.
// Apply the tile boundary exactly once, with transparent pixels outside it.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height,
      let context = CGContext(data: nil, width: 1024, height: 1024,
                              bitsPerComponent: 8, bytesPerRow: 4096,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("Expected a square icon master") }
context.interpolationQuality = .high
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let outline = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.addPath(outline)
context.clip()
context.draw(image, in: tile)
let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
var minX = 1024, minY = 1024, maxX = -1, maxY = -1
for y in 0..<1024 {
    for x in 0..<1024 where bytes[y * 4096 + x * 4 + 3] > 0 {
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
    }
}
guard minX == 100, minY == 100, maxX == 923, maxY == 923
else { fatalError("Unexpected tile bounds: \(minX),\(minY)...\(maxX),\(maxY)") }
guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot write PNG") }
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("PNG write failed") }
print("PASS: 1024px RGBA; 824px tile; 100px transparent margins; one smooth native mask")
