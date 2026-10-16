import XCTest
import Contracts
import Support

final class OutputSettingsTests: XCTestCase {
 func testVirtualPurposeRejectsDefaultPhysicalAndMissingOutputs() {
  let outputs=[OutputDevice(id:"speakers",name:"Speakers"),OutputDevice(id:"blackhole",name:"BlackHole 2ch",isVirtual:true)]
  var settings=Settings();settings.purpose = .virtualMicrophone
  for uid in ["default","speakers","removed"] {
   settings.outputUID=uid
   XCTAssertFalse(SettingsValidator.outputErrors(settings,outputs:outputs).isEmpty)
  }
  print("NEGATIVE virtual output: default, physical and removed device rejected before save/start")
  settings.outputUID="blackhole"
  XCTAssertTrue(SettingsValidator.outputErrors(settings,outputs:outputs).isEmpty)
  print("RECOVERY explicit available BlackHole accepted")
  XCTAssertFalse(SettingsValidator.outputErrors(settings,outputs:[]).isEmpty)
  settings.purpose = .monitor;settings.outputUID="default"
  XCTAssertTrue(SettingsValidator.outputErrors(settings,outputs:outputs).isEmpty)
 }
 func testDiagnosticFileRedactsSecretsAndRemainsBounded() throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/log-test-\(UUID().uuidString)")
  let url=root.appendingPathComponent("diagnostics.log")
  let log=DiagnosticLog(url:url,maximumBytes:400)
  try log.append(LogEntry(module:"audio",stage:"start",message:"token=supersecret serial=privatephone 192.0.2.10"))
  let first=try String(contentsOf:url,encoding:.utf8)
  for secret in ["supersecret","privatephone","192.0.2.10"] {XCTAssertFalse(first.contains(secret))}
  for n in 0..<20 {try log.append(LogEntry(module:"audio",stage:"event",message:"event \(n)"))}
  let data=try Data(contentsOf:url)
  XCTAssertLessThanOrEqual(data.count,400)
  XCTAssertTrue(String(decoding:data,as:UTF8.self).contains("event 19"))
  let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
  XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
 }
}
