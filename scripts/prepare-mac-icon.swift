import AppKit
import Foundation
// Clean geometric mask and standard80% tile coverage; original artwork stays intact.
let input=CommandLine.arguments[1],output=CommandLine.arguments[2]
guard let image=NSImage(contentsOfFile:input),let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{fatalError("Icon image decode/render failed")}
image.size=NSSize(width:1254,height:1254)
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
context.cgContext.clear(CGRect(x:0,y:0,width:1024,height:1024))
context.imageInterpolation = .high
let tile=NSRect(x:102,y:102,width:820,height:820)
let shape=NSBezierPath(roundedRect:tile,xRadius:184,yRadius:184)
NSColor.white.setFill();shape.fill();shape.addClip()
image.draw(in:tile,from:NSRect(x:112,y:120,width:1028,height:1028),operation:.sourceOver,fraction:1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output))
print("Mac icon:1024px RGBA;820px tile;102px transparent margins;clean rounded boundary")
