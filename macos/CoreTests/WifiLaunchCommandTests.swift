import XCTest
import Contracts
@testable import Core

final class WifiLaunchCommandTests: XCTestCase {
 @MainActor func testWifiLaunchMatchesAndroidExtraTypesForBothFormats() throws {
  for format in [PCMFormat.i16, .f32] {
   var settings = Settings()
   settings.audio.format = format
   let args = try SessionController.wifiLaunchArguments(
    settings: settings,
    target: WifiTargetResolution(host: "192.168.1.10", isUserSpecified: false)
   )
   let index = try XCTUnwrap(args.firstIndex(of: "format"))
   XCTAssertEqual(args[index - 1], "--es", "Android reads format with getStringExtra; --ei crashes am start")
   XCTAssertEqual(args[index + 1], format.rawValue)
   for key in ["rate", "channels", "port", "controlPort"] {
    let position = try XCTUnwrap(args.firstIndex(of: key))
    XCTAssertEqual(args[position - 1], "--ei")
    XCTAssertNotNil(Int(args[position + 1]))
   }
  }
 }

 @MainActor func testMacStartReplacesStalePhoneTargetForResolvedAndConfiguredAddresses() throws {
  for userSpecified in [false, true] {
   let args = try SessionController.wifiLaunchArguments(
    settings: Settings(),
    target: WifiTargetResolution(host: "10.98.242.229", isUserSpecified: userSpecified)
   )
   let host = try XCTUnwrap(args.firstIndex(of: "wifiHost"))
   XCTAssertEqual(args[host + 1], "10.98.242.229")
   let explicit = try XCTUnwrap(args.firstIndex(of: "wifiHostExplicit"))
   XCTAssertEqual(args[explicit - 1], "--ez")
   XCTAssertEqual(args[explicit + 1], "true", "A Mac start must replace the phone's previous-network target even when Mac resolved its address automatically")
  }
 }

 @MainActor func testAmbiguousOrMissingAddressCannotLaunchPhone() {
  for target in [
   WifiTargetResolution(host: nil, isUserSpecified: false),
   WifiTargetResolution(host: "192.168.1.10", isUserSpecified: false, isAmbiguous: true)
  ] {
   XCTAssertThrowsError(try SessionController.wifiLaunchArguments(settings: Settings(), target: target))
  }
 }
}
