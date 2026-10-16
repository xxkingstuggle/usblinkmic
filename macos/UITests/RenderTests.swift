import XCTest
import SwiftUI
import AppKit
import Contracts
import UI
final class RenderTests:XCTestCase {
 @MainActor func testStoppedViewsRenderAtNarrowAndWideSizes() throws {
  _ = NSApplication.shared
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/ui-renders")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  for (width,height,appearance) in [(720,520,NSAppearance.Name.aqua),(1280,800,NSAppearance.Name.darkAqua)] {
   var snapshot=AppSnapshot();snapshot.wizardSkipped=true
   let view=NSHostingView(rootView:RootView(snapshot:snapshot,send:{_ in}))
   view.appearance=NSAppearance(named:appearance);view.frame=NSRect(x:0,y:0,width:width,height:height)
   view.layoutSubtreeIfNeeded()
   let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
   view.cacheDisplay(in:view.bounds,to:bitmap)
   let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
   XCTAssertGreaterThan(png.count,1000)
   try png.write(to:root.appendingPathComponent("stopped-\(width)-\(appearance.rawValue).png"))
  }
 }
}
