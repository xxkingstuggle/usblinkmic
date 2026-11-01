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
 func testDiagnosticLogPreservesCriticalEntriesUnderHighFrequencyFloodAndExportsRedactedText() throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/log-critical-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at:root) }
  let url=root.appendingPathComponent("diagnostics.log")
  let log=DiagnosticLog(url:url,maximumBytes:2400)
  try log.append(LogEntry(module:"system",stage:"appBoot",message:"version=4.0.15 boot=abcd1234"))
  try log.append(LogEntry(module:"audio",stage:"start",message:"session=s1 started"))
  try log.append(LogEntry(module:"audio",stage:"failed",message:"OUTPUT_REMOVED: headset unplugged"))
  for i in 0..<80 {
   try log.append(LogEntry(module:"audio",stage:"telemetryTick",message:"non-critical periodic frame count \(i) padding-text"))
  }
  let data=try Data(contentsOf:url)
  XCTAssertLessThanOrEqual(data.count,2400,"Compacted diagnostic log file must remain within maximumBytes")
  let loaded=try log.load()
  XCTAssertTrue(loaded.contains(where:{$0.stage=="appBoot" || $0.stage=="start" || $0.stage=="failed"}),"Critical lifecycle/error entries must survive high-frequency log flood")
  XCTAssertTrue(loaded.contains(where:{$0.message.contains("frame count 79")}),"Newest tail entries must also be retained")
  let exported=try log.exportText()
  XCTAssertTrue(exported.contains("# USBLinkMic Diagnostics v=4.0.15"))
  XCTAssertTrue(exported.contains("frame count 79"))
 }
 func testSettingsValidatorScopedImpactAndWifiTargetHostRules() {
  for invalidHost in ["127.0.0.1","localhost","0.0.0.0","169.254.10.20","10.0.0.2","224.0.0.1"] {
   XCTAssertFalse(SettingsValidator.isUsableWifiTargetHost(invalidHost),"Host \(invalidHost) must be rejected as phone Wi-Fi target")
   var s=Settings()
   s.wifiHost=invalidHost
   XCTAssertFalse(SettingsValidator.errors(s).isEmpty,"SettingsValidator.errors must reject \(invalidHost)")
  }
  for validHost in ["192.168.1.10","10.0.1.8","172.16.0.5","macbook.local"] {
   XCTAssertTrue(SettingsValidator.isUsableWifiTargetHost(validHost),"Host \(validHost) must be accepted as phone Wi-Fi target")
  }

  let base=Settings()
  var gainOnly=base; gainOnly.gain=1.8; gainOnly.muted=true
  XCTAssertEqual(Set(SettingsValidator.changedKeys(from:base,to:gainOnly)),Set(["gain","muted"]))
  XCTAssertTrue(SettingsValidator.affectedWorkspaces(from:base,to:gainOnly).isEmpty,"Gain/mute changes must apply in-place without stopping workspaces")

  var dnsOnly=base; dnsOnly.purpose = .virtualMicrophone; dnsOnly.outputUID="missing"; dnsOnly.dns="8.8.8.8"
  var baseVirtual=base; baseVirtual.purpose = .virtualMicrophone; baseVirtual.outputUID="missing"
  XCTAssertEqual(SettingsValidator.affectedWorkspaces(from:baseVirtual,to:dnsOnly),[.macInternet])
  XCTAssertFalse(SettingsValidator.requiresOutputValidation(from:baseVirtual,to:dnsOnly,microphoneActive:false),"DNS change while microphone is inactive must not require BlackHole output validation")
 }
}
