import XCTest
import Foundation
import CryptoKit
@testable import Core
import Contracts
final class CoreTests:XCTestCase {
 func testMappingCleanupRequiresExactDeviceAndEndpoints(){
  let listing="phoneA tcp:12345 tcp:48125\nphoneB tcp:45678 tcp:48125\n"
  XCTAssertTrue(ADB.ownsMapping(listing,serial:"phoneA",local:"tcp:12345",remote:"tcp:48125"))
  XCTAssertFalse(ADB.ownsMapping(listing,serial:"phoneB",local:"tcp:12345",remote:"tcp:48125"))
  XCTAssertFalse(ADB.ownsMapping(listing,serial:"phoneA",local:"tcp:12345",remote:"tcp:9999"))
 }
 @MainActor func testRecoveryReinstallsMissingCompanionBeforeCleaningPhoneInternet() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-recovery-\(UUID())")
  defer {try? FileManager.default.removeItem(at:root)}
  let adb=root.appendingPathComponent("platform-tools/adb")
  let state=root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:adb.deletingLastPathComponent(),withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true)
  let apk=Data("test companion".utf8)
  try apk.write(to:root.appendingPathComponent("companion.apk"))
  try SHA256.hash(data:apk).map{String(format:"%02x",$0)}.joined()
   .write(to:root.appendingPathComponent("companion.sha256"),atomically:true,encoding:.utf8)
  let session=UUID().uuidString
  let portFile=root.appendingPathComponent("control-port")
  let cancelled=root.appendingPathComponent("cancelled")
  let server=Process()
  server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
  server.arguments=["-c","""
  import json, pathlib, socket, sys
  with socket.socket() as server:
      server.bind(("127.0.0.1", 0))
      server.listen()
      pathlib.Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
      while True:
          conn, _ = server.accept()
          with conn:
              request = json.loads(conn.makefile("rb").readline())
              if request.get("command") == "status" and pathlib.Path(sys.argv[2]).exists():
                  reply = dict(protocol=4, controlRevision=1, session=request["session"],
                               cancelAccepted=True, producerStopped=True)
                  conn.sendall(json.dumps(reply).encode() + bytes([10]))
  """,portFile.path,cancelled.path]
  try server.run()
  defer {server.terminate()}
  for _ in 0..<100 {
   if FileManager.default.fileExists(atPath:portFile.path) {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  let port=try XCTUnwrap(Int(String(contentsOf:portFile,encoding:.utf8)))
  let script="""
  #!/bin/sh
  installed="\(root.path)/installed"
  case "$*" in
    "forward --list") echo "recovery-phone tcp:\(port) tcp:48125";;
    "devices -l") echo "recovery-phone device usb:1-1";;
    "-s recovery-phone install -r \(root.path)/companion.apk") touch "$installed";;
    "-s recovery-phone shell pm list packages com.zjx.usblinkmic")
      if [ -f "$installed" ]; then echo "package:com.zjx.usblinkmic"; fi;;
    "-s recovery-phone shell content call "*)
      [ -f "$installed" ] || exit 1
      echo 'Result: Bundle[{protocol=4, runtimeRevision=\(Capabilities.runtimeRevision), controlComponent=\(Capabilities.androidControlComponent), controlRevision=1}]';;
    "-s recovery-phone shell am start "*)
      [ -f "$installed" ] || exit 1
      touch "\(cancelled.path)";;
    "-s recovery-phone get-state") echo device;;
    "-s recovery-phone shell pm path com.zjx.usblinkmic")
      [ -f "$installed" ] || exit 1
      echo package:/data/app/fake/base.apk;;
    "-s recovery-phone shell setsid "*)
      printf '%s\\n' '{"session":"\(session)","action":"stop","errorCode":17}' > "\(root.path)/ncm-stop";;
    "-s recovery-phone shell cat "*) cat "\(root.path)/ncm-stop";;
    "-s recovery-phone shell env CLASSPATH="*)
      echo '{"session":"\(session)","action":"status","ok":true,"tethered":[]}';;
    "-s recovery-phone shell svc usb getFunctions") echo none;;
  esac
  """
  try script.write(to:adb,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
  let journal=state.appendingPathComponent("owned-sessions.json")
  try """
  [{"id":"\(session)","serial":"recovery-phone","token":"0123456789abcdef0123456789abcdef",
  "module":"phoneInternet","controlForward":\(port),"controlTarget":48125,"oldUSB":"none","ncmRequested":true}]
  """.write(to:journal,atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:root,stateDirectory:state)
  controller.boot()
  for _ in 0..<160 {
   if !controller.snapshot.recoveryMessage.isEmpty {break}
   try await Task.sleep(nanoseconds:50_000_000)
  }
  _ = await controller.shutdown(timeout:1)
  XCTAssertTrue(controller.snapshot.logs.contains{$0.stage=="recoveryCompanionMissing"})
  XCTAssertTrue(controller.snapshot.logs.contains{$0.stage=="cancelAcknowledged"})
  XCTAssertTrue(controller.snapshot.logs.contains{$0.stage=="recovered"},controller.snapshot.recoveryMessage)
  XCTAssertEqual(try String(contentsOf:journal,encoding:.utf8),"[]")
 }
 @MainActor func testReadOnlyCoreAudioOutputDiscovery(){
  let devices=AudioOutput.devices()
  XCTAssertFalse(devices.isEmpty,"This Mac must expose an output for local monitor acceptance")
  XCTAssertEqual(Set(devices.map{$0.id}).count,devices.count)
  XCTAssertTrue(devices.allSatisfy{!$0.id.isEmpty && !$0.name.isEmpty})
  print("PASS CoreAudio read-only discovery: \(devices.count) outputs; no capture or output started")
 }
 func testDeviceParsingKeepsUnauthorizedAndOfflineSeparate(){
  let values=ADB.devices("List of devices attached\na unauthorized\nb device product:x\nc offline\n")
  XCTAssertEqual(values.map{$0.0},["a","b","c"]);XCTAssertEqual(values.map{$0.1},["unauthorized","device","offline"])
 }
 @MainActor func testRefreshSelectsNewUniqueDeviceAfterPreviouslySelectedPhoneDisappears() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-device-switch-\(UUID())")
  defer {try? FileManager.default.removeItem(at:root)}
  let adbDir=root.appendingPathComponent("platform-tools")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  let devicesFile=root.appendingPathComponent("devices.txt")
  let adb=root.appendingPathComponent("platform-tools/adb")
  try "List of devices attached\nold-phone\tdevice usb:1-1\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  let script="""
  #!/bin/sh
  if [ "$1" = "devices" ]; then cat "\(devicesFile.path)"; exit 0; fi
  exit 1
  """
  try script.write(to:adb,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
  let controller=SessionController(resourceRoot:root,stateDirectory:root.appendingPathComponent("state"))
  controller.boot()
  for _ in 0..<100 {
   if controller.snapshot.selectedDeviceID == "old-phone" {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(controller.snapshot.selectedDeviceID,"old-phone")

  try "List of devices attached\nold-phone\toffline usb:1-1\nnew-phone\tdevice usb:1-2\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  controller.send(.refresh)
  for _ in 0..<100 {
   if controller.snapshot.devices.count == 2,controller.snapshot.devices.first(where:{$0.id=="old-phone"})?.state == .offline {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(controller.snapshot.selectedDeviceID,"old-phone","An offline device gets a short re-enumeration grace period")
  for _ in 0..<400 {
   if controller.snapshot.selectedDeviceID == "new-phone" {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(controller.snapshot.devices.map(\.id),["old-phone","new-phone"])
  XCTAssertEqual(controller.snapshot.selectedDeviceID,"new-phone","A sole online device should replace the stale offline selection after the grace period")
  try "List of devices attached\nnew-phone\tdevice usb:1-2\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  controller.send(.refresh)
  for _ in 0..<100 {
   if controller.snapshot.devices.map(\.id) == ["new-phone"] {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  _ = await controller.shutdown(timeout:0.2)

  try "List of devices attached\nold-phone\toffline usb:1-1\nnew-phone\tdevice usb:1-2\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  let bootController=SessionController(resourceRoot:root,stateDirectory:root.appendingPathComponent("boot-state"))
  bootController.boot()
  for _ in 0..<100 {
   if bootController.snapshot.selectedDeviceID == "new-phone" {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(bootController.snapshot.selectedDeviceID,"new-phone","On launch, select the only online phone when stale offline entries remain")
  _ = await bootController.shutdown(timeout:0.2)
 }
 @MainActor func testRefreshPreservesSelectionWhenDeviceListIsUnauthorizedOrAmbiguous() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-device-ambiguous-\(UUID())")
  defer {try? FileManager.default.removeItem(at:root)}
  let adbDir=root.appendingPathComponent("platform-tools")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  let devicesFile=root.appendingPathComponent("devices.txt")
  let adb=root.appendingPathComponent("platform-tools/adb")
  try "List of devices attached\nold-phone\tdevice usb:1-1\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  let script="""
  #!/bin/sh
  if [ "$1" = "devices" ]; then cat "\(devicesFile.path)"; exit 0; fi
  exit 1
  """
  try script.write(to:adb,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
  let controller=SessionController(resourceRoot:root,stateDirectory:root.appendingPathComponent("state"))
  controller.boot()
  for _ in 0..<100 {
   if controller.snapshot.selectedDeviceID == "old-phone" {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  try "List of devices attached\nold-phone\tunauthorized usb:1-1\nnew-phone\tdevice usb:1-2\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  controller.send(.refresh)
  for _ in 0..<100 {
   if controller.snapshot.devices.count == 2 {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(controller.snapshot.selectedDeviceID,"old-phone","Do not switch away from a phone awaiting USB authorization")

  try "List of devices attached\nold-phone\toffline usb:1-1\nnew-phone\tdevice usb:1-2\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  controller.send(.refresh)
  for _ in 0..<100 {
   if controller.snapshot.devices.first(where:{$0.id=="old-phone"})?.state == .offline {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(controller.snapshot.devices.first(where:{$0.id=="old-phone"})?.state,.offline)
  XCTAssertEqual(controller.snapshot.selectedDeviceID,"old-phone","An offline/re-enumerating phone keeps its selection while another device is also present")

  try "List of devices attached\nnew-phone\tdevice usb:1-2\nthird-phone\tdevice usb:1-3\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  controller.send(.refresh)
  for _ in 0..<100 {
   if controller.snapshot.devices.map(\.id)==["new-phone","third-phone"] {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(controller.snapshot.devices.map(\.id),["new-phone","third-phone"])
  XCTAssertEqual(controller.snapshot.selectedDeviceID,"old-phone","Multiple available phones require an explicit user choice")
  _ = await controller.shutdown(timeout:0.2)
 }
 @MainActor func testOfflinePreviousDeviceDoesNotOccupyNewDevicesSessionSlot() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-offline-session-\(UUID())")
  defer {try? FileManager.default.removeItem(at:root)}
  let adbDir=root.appendingPathComponent("platform-tools")
  let state=root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true)
  let invocationLog=root.appendingPathComponent("adb.log")
  let adb=root.appendingPathComponent("platform-tools/adb")
  let script="""
  #!/bin/sh
  printf '%s\\n' "$*" >> "\(invocationLog.path)"
  if [ "$1" = "devices" ]; then
   echo "List of devices attached"
   echo "new-phone device usb:1-2"
   exit 0
  fi
  exit 1
  """
  try script.write(to:adb,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
  let session=UUID().uuidString
  let secondSession=UUID().uuidString
  let ncmSession=UUID().uuidString
  let journal=state.appendingPathComponent("owned-sessions.json")
  try """
  [{"id":"\(session)","serial":"old-phone","token":"0123456789abcdef0123456789abcdef","reverse":"localabstract:usblinkmic-v4","module":"macInternet"},
   {"id":"\(secondSession)","serial":"old-phone","token":"abcdef0123456789abcdef0123456789","reverse":"localabstract:usblinkmic-v4","module":"macInternet"},
   {"id":"\(ncmSession)","serial":"old-phone","token":"123456789abcdef0123456789abcdef0","oldUSB":"adb","ncmRequested":true,"ncmUSBChanged":true,"module":"phoneInternet"}]
  """.write(to:journal,atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:root,stateDirectory:state)
  controller.boot()
  for _ in 0..<100 {
   if controller.snapshot.selectedDeviceID == "new-phone",!controller.snapshot.recoveryMessage.isEmpty,!controller.recovering {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  controller.send(.start(.phoneInternet))
  for _ in 0..<100 {
   if (try? String(contentsOf:invocationLog,encoding:.utf8).contains("-s new-phone shell pm list packages")) == true {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  let invocations=(try? String(contentsOf:invocationLog,encoding:.utf8)) ?? ""
  XCTAssertTrue(invocations.contains("-s new-phone shell pm list packages com.zjx.usblinkmic"),"A stale offline record must not occupy the new phone's module slot")
  XCTAssertFalse(invocations.contains("-s new-phone reverse --remove"),"Recovery commands must stay bound to the original phone identity")
  let persisted=try String(contentsOf:journal,encoding:.utf8)
  XCTAssertTrue(persisted.contains("old-phone"),"Unreachable phone-side cleanup must remain durably associated with its original serial")
  XCTAssertTrue(persisted.contains(secondSession),"Multiple old records for the same module must survive together")
  XCTAssertTrue(persisted.contains(ncmSession),"NCM cleanup receipts must remain tied to the disconnected phone")
  _ = await controller.shutdown(timeout:0.2)

  let restarted=SessionController(resourceRoot:root,stateDirectory:state)
  restarted.boot()
  for _ in 0..<100 {
   if restarted.snapshot.selectedDeviceID == "new-phone",!restarted.snapshot.recoveryMessage.isEmpty,!restarted.recovering {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  restarted.send(.start(.phoneInternet))
  for _ in 0..<100 {
   if (try? String(contentsOf:invocationLog,encoding:.utf8).components(separatedBy:"-s new-phone shell pm list packages").count) ?? 0 >= 3 {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  let afterRestart=(try? String(contentsOf:invocationLog,encoding:.utf8)) ?? ""
  XCTAssertGreaterThanOrEqual(afterRestart.components(separatedBy:"-s new-phone shell pm list packages").count-1,2,"A persisted old-device record must not occupy the new phone's session slot after restart")
  XCTAssertTrue(try String(contentsOf:journal,encoding:.utf8).contains("old-phone"))
  _ = await restarted.shutdown(timeout:0.2)
 }
 @MainActor func testReconnectedPhoneRetriesItsOwnPendingCleanup() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-reconnect-recovery-\(UUID())")
  defer {try? FileManager.default.removeItem(at:root)}
  let adbDir=root.appendingPathComponent("platform-tools")
  let state=root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true)
  let devicesFile=root.appendingPathComponent("devices.txt")
  let invocations=root.appendingPathComponent("adb.log")
  let adb=root.appendingPathComponent("platform-tools/adb")
  try "List of devices attached\nnew-phone device usb:1-2\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  let script="""
  #!/bin/sh
  printf '%s\\n' "$*" >> "\(invocations.path)"
  if [ "$1" = "devices" ]; then cat "\(devicesFile.path)"; exit 0; fi
  if [ "$1" = "-s" ] && [ "$2" = "old-phone" ]; then
   shift 2
   if [ "$1" = "reverse" ] && [ "$2" = "--list" ]; then echo "old-phone localabstract:usblinkmic-v4 tcp:48128"; exit 0; fi
   if [ "$1" = "reverse" ] && [ "$2" = "--remove" ]; then exit 0; fi
  fi
  exit 1
  """
  try script.write(to:adb,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
  let session=UUID().uuidString
  let journal=state.appendingPathComponent("owned-sessions.json")
  try """
  [{"id":"\(session)","serial":"old-phone","token":"0123456789abcdef0123456789abcdef","reverse":"localabstract:usblinkmic-v4","module":"macInternet"}]
  """.write(to:journal,atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:root,stateDirectory:state)
  controller.boot()
  for _ in 0..<100 {
   if controller.snapshot.selectedDeviceID == "new-phone",!controller.snapshot.recoveryMessage.isEmpty {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertTrue(try String(contentsOf:journal,encoding:.utf8).contains(session))
  try "List of devices attached\nnew-phone device usb:1-2\nold-phone device usb:1-1\n".write(to:devicesFile,atomically:true,encoding:.utf8)
  controller.send(.refresh)
  for _ in 0..<150 {
   if !((try? String(contentsOf:journal,encoding:.utf8)) ?? "").contains(session) {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  let calls=(try? String(contentsOf:invocations,encoding:.utf8)) ?? ""
  XCTAssertTrue(calls.contains("-s old-phone reverse --remove localabstract:usblinkmic-v4"),"Recovery must address the session's original phone; calls=\(calls), message=\(controller.snapshot.recoveryMessage)")
  XCTAssertFalse(calls.contains("-s new-phone reverse --remove"),"The replacement phone must never receive an old session's cleanup command")
  XCTAssertFalse(try String(contentsOf:journal,encoding:.utf8).contains(session))
  _ = await controller.shutdown(timeout:0.2)
 }
 @MainActor func testDeferredStartStopsWhenSelectionOrStopChangesDuringRecovery() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-cancel-deferred-start-\(UUID())")
  defer {try? FileManager.default.removeItem(at:root)}
  let adbDir=root.appendingPathComponent("platform-tools")
  let state=root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true)
  let invocations=root.appendingPathComponent("adb.log")
  let countFile=root.appendingPathComponent("reverse-count")
  let enteredFile=root.appendingPathComponent("reverse-entered")
  let releaseFile=root.appendingPathComponent("reverse-release")
  let devicesFile=root.appendingPathComponent("devices.txt")
  try "List of devices attached\nold-phone device usb:1-1\nnew-phone device usb:1-2\n"
   .write(to:devicesFile,atomically:true,encoding:.utf8)
  let adb=root.appendingPathComponent("platform-tools/adb")
  let script="""
  #!/bin/sh
  printf '%s\\n' "$*" >> "\(invocations.path)"
  if [ "$1" = "devices" ]; then cat "\(devicesFile.path)"; exit 0; fi
  if [ "$1" = "-s" ] && [ "$2" = "old-phone" ] && [ "$3" = "reverse" ] && [ "$4" = "--list" ]; then
   count=$(cat "\(countFile.path)" 2>/dev/null || echo 0)
   count=$((count + 1))
   printf '%s' "$count" > "\(countFile.path)"
   if [ "$count" -le 2 ]; then exit 1; fi
   printf '%s' "$count" > "\(enteredFile.path)"
   while [ "$(cat "\(releaseFile.path)" 2>/dev/null || echo 0)" -lt "$count" ]; do /bin/sleep 0.02; done
   echo "old-phone localabstract:usblinkmic-v4 tcp:48128"
   exit 0
  fi
  if [ "$1" = "-s" ] && [ "$2" = "old-phone" ] && [ "$3" = "reverse" ] && [ "$4" = "--remove" ]; then exit 0; fi
  exit 1
  """
  try script.write(to:adb,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
  let first=UUID().uuidString,second=UUID().uuidString
  try """
  [{"id":"\(first)","serial":"old-phone","token":"0123456789abcdef0123456789abcdef","reverse":"localabstract:usblinkmic-v4","module":"macInternet"},
   {"id":"\(second)","serial":"old-phone","token":"abcdef0123456789abcdef0123456789","reverse":"localabstract:usblinkmic-v4","module":"macInternet"}]
  """.write(to:state.appendingPathComponent("owned-sessions.json"),atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:root,stateDirectory:state)
  controller.boot()
  for _ in 0..<150 {
   if !controller.recovering,controller.snapshot.recoveryMessage.contains("待清理") {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertTrue(controller.snapshot.devices.contains(where:{$0.id=="old-phone" && $0.state == .online}))
  XCTAssertTrue(try String(contentsOf:state.appendingPathComponent("owned-sessions.json"),encoding:.utf8).contains(first))
  controller.send(.selectDevice("old-phone"))
  controller.send(.start(.phoneInternet))
  for _ in 0..<150 {
   if (try? String(contentsOf:enteredFile,encoding:.utf8)) == "3" {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(try String(contentsOf:enteredFile,encoding:.utf8),"3","Starting for a phone with pending history must wait on that phone's cleanup")
  controller.send(.selectDevice("new-phone"))
  try "3".write(to:releaseFile,atomically:true,encoding:.utf8)
  for _ in 0..<150 {
   let journal=(try? String(contentsOf:state.appendingPathComponent("owned-sessions.json"),encoding:.utf8)) ?? ""
   if !journal.contains(first),journal.contains(second) {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  let afterSwitch=try String(contentsOf:state.appendingPathComponent("owned-sessions.json"),encoding:.utf8)
  XCTAssertFalse(afterSwitch.contains(first))
  XCTAssertTrue(afterSwitch.contains(second))
  XCTAssertEqual(controller.snapshot.selectedDeviceID,"new-phone")

  controller.send(.selectDevice("old-phone"))
  controller.send(.start(.phoneInternet))
  for _ in 0..<150 {
   if (try? String(contentsOf:enteredFile,encoding:.utf8)) == "4" {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertEqual(try String(contentsOf:enteredFile,encoding:.utf8),"4","The next deferred start should wait for its remaining old-device record")
  controller.send(.stop(.phoneInternet))
  try "4".write(to:releaseFile,atomically:true,encoding:.utf8)
  try await Task.sleep(nanoseconds:400_000_000)
  let calls=(try? String(contentsOf:invocations,encoding:.utf8)) ?? ""
  XCTAssertFalse(calls.contains("shell pm list packages"),"A selection change or Stop must cancel the deferred start before it launches a new phone session")
  XCTAssertFalse(calls.contains("shell am start"),"An old cleanup result must not restart the task after user intent changed")
  XCTAssertFalse(try String(contentsOf:state.appendingPathComponent("owned-sessions.json"),encoding:.utf8).contains(second))
  _ = await controller.shutdown(timeout:0.2)
 }
 func testInstallErrorsDoNotSuggestUninstall(){
  XCTAssertEqual(ADB.classify("INSTALL_FAILED_UPDATE_INCOMPATIBLE"),"INSTALL_SIGNATURE_CONFLICT")
  XCTAssertEqual(ADB.classify("INSTALL_FAILED_VERSION_DOWNGRADE"),"INSTALL_DOWNGRADE")
  XCTAssertEqual(ADB.classify("INSTALL_FAILED_USER_RESTRICTED"),"INSTALL_DENIED")
 }
 func testFragmentedSilentFramesRemainValid()throws{
  var decoder=FrameDecoder()
  XCTAssertTrue(try decoder.append(Data([0,0]),bytesPerFrame:2).isEmpty)
  XCTAssertTrue(try decoder.append(Data([0,4,0]),bytesPerFrame:2).isEmpty)
  let result=try decoder.append(Data([0,0,0,0,0,0,2,1,0]),bytesPerFrame:2)
  XCTAssertEqual(result,[Data([0,0,0,0]),Data([1,0])])
 }
 func testBadFrameDetectedThenFreshDecoderRecovers()throws{
  var decoder=FrameDecoder()
  XCTAssertThrowsError(try decoder.append(Data([0,0,0,3,1,2,3]),bytesPerFrame:2))
  print("NEGATIVE BAD_FRAME detected (unaligned length=3)")
  decoder=FrameDecoder()
  XCTAssertEqual(try decoder.append(Data([0,0,0,2,1,0]),bytesPerFrame:2),[Data([1,0])])
  print("RECOVERY fresh decoder accepted aligned frame")
 }
 func testOversizedAndZeroFramesRejected(){
  for bytes:[UInt8] in [[0,0,0,0],[0,4,0,1]]{var decoder=FrameDecoder();XCTAssertThrowsError(try decoder.append(Data(bytes),bytesPerFrame:2))}
 }
 func testInterfacesIgnoreLoopbackAndNonEthernet(){
  let list=NetworkProbe.parseInterfaces("lo0: flags=0\n\tinet 127.0.0.1 netmask 0xff\nen9: flags=0\n\tinet 192.0.2.1 netmask 0xff\nutun1: flags=0\n\tinet 10.0.0.2 netmask 0xff\n")
  XCTAssertEqual(list,[NetworkInterface(name:"en9",address:"192.0.2.1")])
 }
 func testTaskCancellationTerminatesOwnedProcess() async throws {
  let started=Date()
  let task=Task{try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sleep"),["10"])}
  try await Task.sleep(nanoseconds:100_000_000);task.cancel()
  let result=try await task.value
  XCTAssertNotEqual(result.code,0);XCTAssertLessThan(Date().timeIntervalSince(started),3)
  print("PASS cancellation terminated only owned process")
 }
 func testCommandExitCodeAndTimeoutAreObserved() async throws {
  let bad=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/false"),[])
  XCTAssertNotEqual(bad.code,0);print("NEGATIVE process exit=\(bad.code) detected")
  let good=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/true"),[])
  XCTAssertEqual(good.code,0);print("RECOVERY process exit=\(good.code)")
  let begin=Date();let timed=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sleep"),["10"],timeout:0.1)
  XCTAssertNotEqual(timed.code,0);XCTAssertLessThan(Date().timeIntervalSince(begin),3)
 }
 func testTimeoutBoundsPipeWaitWhenParentExitsAndCleansUpDescendant() async throws {
  let begin=Date()
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sh"),["-c","/bin/sleep 4 & echo $!; exit 0"],timeout:0.2)
  let elapsed=Date().timeIntervalSince(begin)
  let childPID=pid_t(result.output.trimmingCharacters(in:.whitespacesAndNewlines))
  defer { if let pid=childPID { _ = Darwin.kill(pid,SIGKILL) } }
  XCTAssertLessThan(elapsed,1.5,"Timeout must bound pipe wait even after direct parent exits")
  XCTAssertNotEqual(result.code,0,"Timed out command must not report exit code 0")
  if let pid=childPID {
   XCTAssertNotEqual(Darwin.kill(pid,0),0,"Descendant holding stdout pipe must be terminated on timeout")
  } else {
   XCTFail("Expected background child PID in stdout, got: \(result.output)")
  }
 }
 func testCancellationBoundsPipeWaitWhenParentExitsAndCleansUpDescendant() async throws {
  let begin=Date()
  let task=Task { try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sh"),["-c","/bin/sleep 4 & echo $!; exit 0"],timeout:10) }
  try await Task.sleep(nanoseconds:150_000_000)
  task.cancel()
  let result=try await task.value
  let elapsed=Date().timeIntervalSince(begin)
  let childPID=pid_t(result.output.trimmingCharacters(in:.whitespacesAndNewlines))
  defer { if let pid=childPID { _ = Darwin.kill(pid,SIGKILL) } }
  XCTAssertLessThan(elapsed,1.5,"Cancellation must bound pipe wait even after direct parent exits")
  XCTAssertNotEqual(result.code,0)
  if let pid=childPID {
   XCTAssertNotEqual(Darwin.kill(pid,0),0,"Descendant holding stdout pipe must be terminated on cancellation")
  } else {
   XCTFail("Expected background child PID in stdout, got: \(result.output)")
  }
 }
 func testTimeoutEscalatesToSIGKILLWhenProcessAndDescendantIgnoreSIGTERM() async throws {
  let begin=Date()
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sh"),["-c","trap '' TERM; /bin/sleep 4 & echo $!; wait"],timeout:0.2)
  let elapsed=Date().timeIntervalSince(begin)
  let childPID=pid_t(result.output.trimmingCharacters(in:.whitespacesAndNewlines))
  defer { if let pid=childPID { _ = Darwin.kill(pid,SIGKILL) } }
  XCTAssertLessThan(elapsed,1.5,"SIGTERM-ignoring process group must be SIGKILLed within short grace period")
  XCTAssertNotEqual(result.code,0)
  if let pid=childPID {
   XCTAssertNotEqual(Darwin.kill(pid,0),0,"Descendant in SIGTERM-ignoring shell must be terminated")
  } else {
   XCTFail("Expected child PID in stdout, got: \(result.output)")
  }
 }
 @MainActor func testShutdownPreservesPendingPhoneCleanupWhenPhoneDisconnected() async throws {
  let tempDir=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-test-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at:tempDir) }
  let adbDir=tempDir.appendingPathComponent("platform-tools")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  let adbURL=adbDir.appendingPathComponent("adb")
  let sessionID=UUID().uuidString
  let closedPort=59187
  let adbScript="""
  #!/bin/sh
  if [ "$1" = "forward" ] && [ "$2" = "--list" ]; then
   echo "phone-serial-1 tcp:\(closedPort) tcp:48125"
   exit 0
  fi
  if [ "$1" = "forward" ] && [ "$2" = "--remove" ]; then exit 0; fi
  if [ "$1" = "devices" ]; then
   echo "List of devices attached"
   exit 0
  fi
  echo "adb: error: device 'phone-serial-1' not found" >&2
  exit 1
  """
  try adbScript.write(to:adbURL,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adbURL.path)
  let stateDir=tempDir.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:stateDir,withIntermediateDirectories:true)
  let journalURL=stateDir.appendingPathComponent("owned-sessions.json")
  let journalJSON="""
  [{"id":"\(sessionID)","serial":"phone-serial-1","token":"secret-token","controlForward":\(closedPort),"controlTarget":48125,"module":"microphone"}]
  """
  try journalJSON.write(to:journalURL,atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:tempDir,stateDirectory:stateDir)
  controller.boot()
  let shouldTerminate=await controller.shutdown()
  XCTAssertTrue(shouldTerminate,"Cmd+Q must allow termination when old-phone cleanup can only be deferred")
  XCTAssertEqual(controller.snapshot.microphone.phase,.stopped,"Mac-side cleanup should finish without claiming the offline phone was contacted")
  XCTAssertNil(controller.snapshot.microphone.errorCode)
  XCTAssertTrue(controller.snapshot.logs.contains(where:{$0.stage=="recoveryDeferred"}),"The original phone-side cleanup must remain pending")
  let preserved=try String(contentsOf:journalURL,encoding:.utf8)
  XCTAssertTrue(preserved.contains(sessionID),"Uncleaned session must remain in durable journal for next launch recovery")
 }
 func testLargeOutputDoesNotDeadlockAndIsCappedAtTwoMegabytes() async throws {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sh"),["-c","head -c 2500000 /dev/zero | tr '\\0' 'a'"],timeout:5)
  XCTAssertEqual(result.code,0)
  XCTAssertEqual(result.output.utf8.count,2_000_000)
 }
 func testSpawnFailureThrowsPromptly() async {
  let begin=Date()
  do {
   _ = try await ProcessRunner.run(URL(fileURLWithPath:"/nonexistent/usblinkmic-missing-binary"),[],timeout:5)
   XCTFail("Expected missing executable to throw")
  } catch {
   XCTAssertLessThan(Date().timeIntervalSince(begin),1.0)
  }
 }
 @MainActor func testShutdownTotalDeadlineBoundsHungCleanupAndPreventsPostDeadlineMutations() async throws {
  let tempDir=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-deadline-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at:tempDir) }
  let adbDir=tempDir.appendingPathComponent("platform-tools")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  let adbURL=adbDir.appendingPathComponent("adb")
  let invocationsURL=tempDir.appendingPathComponent("adb-invocations.log")
  let hungPIDURL=tempDir.appendingPathComponent("hung-sleep.pid")
  let sessionID=UUID().uuidString
  let closedPort=59188
  let adbScript="""
  #!/bin/sh
  echo "$(date +%s) $*" >> "\(invocationsURL.path)"
  if [ "$1" = "devices" ]; then
   echo "List of devices attached"
   echo "phone-serial-2 device usb:1-2"
   exit 0
  fi
  if [ "$1" = "forward" ] && [ "$2" = "--list" ]; then
   echo "phone-serial-2 tcp:\(closedPort) tcp:48125"
   exit 0
  fi
  if [ "$1 $2 $3 $4 $5 $6" = "-s phone-serial-2 shell pm list packages" ]; then
   echo "package:com.zjx.usblinkmic"
   exit 0
  fi
  if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "content" ]; then
   /bin/sleep 6 &
   echo $! > "\(hungPIDURL.path)"
   wait
   exit 0
  fi
  exit 0
  """
  try adbScript.write(to:adbURL,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adbURL.path)
  let stateDir=tempDir.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:stateDir,withIntermediateDirectories:true)
  let journalURL=stateDir.appendingPathComponent("owned-sessions.json")
  let journalJSON="""
  [{"id":"\(sessionID)","serial":"phone-serial-2","token":"secret-token","controlForward":\(closedPort),"controlTarget":48125,"oldUSB":"adb","ncmRequested":true,"module":"phoneInternet"}]
  """
  try journalJSON.write(to:journalURL,atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:tempDir,stateDirectory:stateDir)
  controller.boot()
  for _ in 0..<100 {
   if FileManager.default.fileExists(atPath:hungPIDURL.path) {break}
   try await Task.sleep(nanoseconds:20_000_000)
  }
  XCTAssertTrue(FileManager.default.fileExists(atPath:hungPIDURL.path),"Recovery must reach the deliberately hung phone command before testing the shutdown deadline")
  let begin=Date()
  let shouldTerminate=await controller.shutdown(timeout:0.35)
  let elapsed=Date().timeIntervalSince(begin)
  let hungPID:pid_t? = (try? String(contentsOf:hungPIDURL,encoding:.utf8)).flatMap { pid_t($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
  defer { if let pid=hungPID { _ = Darwin.kill(pid,SIGKILL) } }
  XCTAssertTrue(shouldTerminate)
  XCTAssertLessThan(elapsed,1.5,"Shutdown must finish within short total deadline even when cleanup hangs")
  XCTAssertEqual(controller.snapshot.phoneInternet.phase,.failed,"Timed out shutdown must not claim cleanup succeeded")
  XCTAssertEqual(controller.snapshot.phoneInternet.errorCode,"CLEANUP_INCOMPLETE")
  let preserved=try String(contentsOf:journalURL,encoding:.utf8)
  XCTAssertTrue(preserved.contains(sessionID),"Durable journal must retain uncleaned session after deadline")
  let countAtReturn=(try? String(contentsOf:invocationsURL,encoding:.utf8).split(separator:"\n").count) ?? 0
  if let pid=hungPID {
   XCTAssertNotEqual(Darwin.kill(pid,0),0,"Hung cleanup subprocess must be terminated at shutdown deadline")
  }
  try await Task.sleep(nanoseconds:300_000_000)
  let countAfterWait=(try? String(contentsOf:invocationsURL,encoding:.utf8).split(separator:"\n").count) ?? 0
  XCTAssertEqual(countAfterWait,countAtReturn,"No new adb or USB/network mutations may start after shutdown deadline")
  let logAfterDeadline=(try? String(contentsOf:invocationsURL,encoding:.utf8)) ?? ""
  XCTAssertFalse(logAfterDeadline.contains("setFunctions"),"Must not run USB restoration after deadline expired")
 }
 @MainActor func testTerminationCoordinatorHandlesRepeatedCmdQAndDeadlineRaceWithSingleReply() async throws {
  let tempDir=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-coord-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at:tempDir) }
  let adbDir=tempDir.appendingPathComponent("platform-tools")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  let adbURL=adbDir.appendingPathComponent("adb")
  let sessionID=UUID().uuidString
  let closedPort=59189
  let adbScript="""
  #!/bin/sh
  if [ "$1" = "forward" ] && [ "$2" = "--list" ]; then
   echo "phone-serial-3 tcp:\(closedPort) tcp:48125"
   exit 0
  fi
  /bin/sleep 4
  exit 1
  """
  try adbScript.write(to:adbURL,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adbURL.path)
  let stateDir=tempDir.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:stateDir,withIntermediateDirectories:true)
  let journalURL=stateDir.appendingPathComponent("owned-sessions.json")
  let journalJSON="""
  [{"id":"\(sessionID)","serial":"phone-serial-3","token":"secret-token","controlForward":\(closedPort),"controlTarget":48125,"module":"microphone"}]
  """
  try journalJSON.write(to:journalURL,atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:tempDir,stateDirectory:stateDir)
  controller.boot()
  let coordinator=TerminationCoordinator()
  var replies=[Bool]()
  let r1=coordinator.requestTermination(controller:controller,shutdownTimeout:0.3,fallbackTimeout:0.2) { replies.append($0) }
  let r2=coordinator.requestTermination(controller:controller,shutdownTimeout:0.3,fallbackTimeout:0.2) { replies.append($0) }
  let r3=coordinator.requestTermination(controller:controller,shutdownTimeout:0.3,fallbackTimeout:0.2) { replies.append($0) }
  XCTAssertEqual(r1,.terminateLater)
  XCTAssertEqual(r2,.terminateLater)
  XCTAssertEqual(r3,.terminateLater)
  try await Task.sleep(nanoseconds:550_000_000)
  XCTAssertEqual(replies,[true],"Repeated Cmd+Q and fallback/shutdown race must reply true exactly once")
  let preserved=try String(contentsOf:journalURL,encoding:.utf8)
  XCTAssertTrue(preserved.contains(sessionID))
 }
 func testContinuousFastWriterDoesNotStarveTimeout() async throws {
  let begin=Date()
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/python3"),["-c","import os; b=b'x'*65536\nwhile True:\n try: os.write(1, b)\n except OSError: break"],timeout:0.25)
  let elapsed=Date().timeIntervalSince(begin)
  XCTAssertNotEqual(result.code,0)
  XCTAssertLessThan(elapsed,1.5,"Continuous fast output must not starve the timeout timer on the serial queue")
 }
 func testEscapedProcessGroupHoldingPipeStillRespectsTimeout() async throws {
  let pidFile=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-setsid-\(UUID().uuidString).pid")
  defer { try? FileManager.default.removeItem(at:pidFile) }
  var escapedPID:pid_t? = nil
  defer { if let pid=escapedPID { _ = Darwin.kill(pid,SIGKILL) } }
  let script="""
  import os, time
  pid = os.fork()
  if pid == 0:
      os.setsid()
      with open(\( String(reflecting: pidFile.path) ), "w") as f:
          f.write(str(os.getpid()))
      time.sleep(5)
      os._exit(0)
  os._exit(0)
  """
  let begin=Date()
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/python3"),["-c",script],timeout:0.25)
  let elapsed=Date().timeIntervalSince(begin)
  escapedPID=(try? String(contentsOf:pidFile,encoding:.utf8)).flatMap { pid_t($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
  XCTAssertNotEqual(result.code,0)
  XCTAssertLessThan(elapsed,1.5,"Pipe wait must be bounded even when a descendant escapes the process group via setsid")
 }
 func testRapidCommandsAndCancellationDoNotLeakDescriptorsOrHang() async throws {
  for i in 0..<25 {
   if i % 3 == 0 {
    let task=Task {
     try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sleep"),["3"],timeout:5)
    }
    try await Task.sleep(nanoseconds:15_000_000)
    task.cancel()
    _ = try? await task.value
   } else {
    let res=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/echo"),["iter-\(i)"],timeout:2)
    XCTAssertEqual(res.code,0)
    XCTAssertEqual(res.output.trimmingCharacters(in:.whitespacesAndNewlines),"iter-\(i)")
   }
  }
 }
 func testClosedStdoutDoesNotDisableTimeoutOrNormalCompletion() async throws {
  let ok=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sh"),["-c","exec >/dev/null 2>&1; exit 0"],timeout:2)
  XCTAssertEqual(ok.code,0)

  let begin=Date()
  let timed=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sh"),["-c","exec >/dev/null 2>&1; /bin/sleep 2"],timeout:0.2)
  let elapsed=Date().timeIntervalSince(begin)
  XCTAssertNotEqual(timed.code,0,"EOF on stdout/stderr must not cancel deadline while leader is still running")
  XCTAssertLessThan(elapsed,1.5,"Closed-output command must still time out in bounded time")
 }
 func testClosedStdoutParentAndDescendantIgnoringSIGTERMStillKilledOnTimeoutAndCancel() async throws {
  let pidFile1=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-closed-term-1-\(UUID().uuidString).pid")
  let pidFile2=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-closed-term-2-\(UUID().uuidString).pid")
  let pidFile3=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-closed-term-3-\(UUID().uuidString).pid")
  defer {
   try? FileManager.default.removeItem(at:pidFile1)
   try? FileManager.default.removeItem(at:pidFile2)
   try? FileManager.default.removeItem(at:pidFile3)
  }
  var pid1:pid_t?=nil
  var pid2:pid_t?=nil
  var pid3:pid_t?=nil
  defer {
   if let p=pid1 { _ = Darwin.kill(p,SIGKILL) }
   if let p=pid2 { _ = Darwin.kill(p,SIGKILL) }
   if let p=pid3 { _ = Darwin.kill(p,SIGKILL) }
  }

  let begin1=Date()
  let res1=try await ProcessRunner.run(
   URL(fileURLWithPath:"/bin/sh"),
   ["-c","exec >/dev/null 2>&1; trap '' TERM; /bin/sleep 4 & echo $! > \"\(pidFile1.path)\"; wait"],
   timeout:0.2
  )
  let elapsed1=Date().timeIntervalSince(begin1)
  pid1=(try? String(contentsOf:pidFile1,encoding:.utf8)).flatMap { pid_t($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
  XCTAssertNotEqual(res1.code,0)
  XCTAssertLessThan(elapsed1,1.5)
  if let p=pid1 {
   XCTAssertNotEqual(Darwin.kill(p,0),0,"Silent SIGTERM-ignoring descendant must be SIGKILLed on timeout")
  } else {
   XCTFail("Expected descendant PID in pidFile1")
  }

  let begin2=Date()
  let task2=Task {
   try await ProcessRunner.run(
    URL(fileURLWithPath:"/bin/sh"),
    ["-c","exec >/dev/null 2>&1; trap '' TERM; /bin/sleep 4 & echo $! > \"\(pidFile2.path)\"; wait"],
    timeout:10
   )
  }
  try await Task.sleep(nanoseconds:150_000_000)
  task2.cancel()
  let res2=try await task2.value
  let elapsed2=Date().timeIntervalSince(begin2)
  pid2=(try? String(contentsOf:pidFile2,encoding:.utf8)).flatMap { pid_t($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
  XCTAssertNotEqual(res2.code,0)
  XCTAssertLessThan(elapsed2,1.5)
  if let p=pid2 {
   XCTAssertNotEqual(Darwin.kill(p,0),0,"Silent SIGTERM-ignoring descendant must be SIGKILLed on task cancellation")
  } else {
   XCTFail("Expected descendant PID in pidFile2")
  }

  let group=ProcessGroupCancellation()
  let begin3=Date()
  let task3=Task {
   try await ProcessRunner.$currentGroup.withValue(group) {
    try await ProcessRunner.run(
     URL(fileURLWithPath:"/bin/sh"),
     ["-c","exec >/dev/null 2>&1; trap '' TERM; /bin/sleep 4 & echo $! > \"\(pidFile3.path)\"; /bin/sleep 4"],
     timeout:10
    )
   }
  }
  try await Task.sleep(nanoseconds:150_000_000)
  group.cancelAll()
  let res3=try await task3.value
  let elapsed3=Date().timeIntervalSince(begin3)
  pid3=(try? String(contentsOf:pidFile3,encoding:.utf8)).flatMap { pid_t($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
  XCTAssertNotEqual(res3.code,0)
  XCTAssertLessThan(elapsed3,1.5)
  if let p=pid3 {
   XCTAssertNotEqual(Darwin.kill(p,0),0,"Silent SIGTERM-ignoring descendant must be SIGKILLed on group deadline cancellation")
  } else {
   XCTFail("Expected descendant PID in pidFile3")
  }
 }
 func testPendingSpawnReservationBoundsCancelAllAndTerminatesRacingSpawns() async throws {
  let group1=ProcessGroupCancellation()
  XCTAssertTrue(group1.beginSpawn())
  DispatchQueue.global().asyncAfter(deadline:.now()+0.75) {
   group1.completeSpawn(UUID(),execution:nil)
  }
  let began=ProcessInfo.processInfo.systemUptime
  group1.cancelAll()
  let elapsed=ProcessInfo.processInfo.systemUptime-began
  XCTAssertLessThan(elapsed,0.25,"cancelAll must not block indefinitely on a stalled pending spawn reservation")
  XCTAssertFalse(group1.beginSpawn(),"Cancelled group must reject subsequent spawn reservations")

  for _ in 0..<8 {
   let group2=ProcessGroupCancellation()
   let task=Task {
    try await ProcessRunner.$currentGroup.withValue(group2) {
     try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sleep"),["3"],timeout:5)
    }
   }
   try await Task.sleep(nanoseconds:1_000_000)
   group2.cancelAll()
   let res=try await task.value
   XCTAssertNotEqual(res.code,0,"Racing child process must be terminated when group is cancelled")
  }
 }
 @MainActor func testSaveSettingsAndStopPhoneInternetSucceedWhenOldUSBIsNone() async throws {
  let tempDir=FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-oldusb-none-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at:tempDir) }
  let adbDir=tempDir.appendingPathComponent("platform-tools")
  try FileManager.default.createDirectory(at:adbDir,withIntermediateDirectories:true)
  let adbURL=adbDir.appendingPathComponent("adb")
  let usbStateFile=tempDir.appendingPathComponent("usb-functions.txt")
  try "ncm".write(to:usbStateFile,atomically:true,encoding:.utf8)
  let sessionID=UUID().uuidString
  let adbScript="""
  #!/bin/sh
  if [ "$1" = "devices" ]; then
   echo "List of devices attached"
   echo "phone-serial-none\tdevice"
   exit 0
  fi
  if [ "$1" = "forward" ] && [ "$2" = "--list" ]; then
   exit 0
  fi
  if [ "$1" = "-s" ]; then
   shift 2
  fi
  if [ "$1" = "get-state" ]; then
   echo "device"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = "svc" ] && [ "$3" = "usb" ] && [ "$4" = "getFunctions" ]; then
   cat "\(usbStateFile.path)"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = " getprop" ] || [ "$2" = "getprop" ]; then
   cat "\(usbStateFile.path)"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = "svc" ] && [ "$3" = "usb" ] && [ "$4" = "setFunctions" ]; then
   if [ "$5" = "none" ]; then
    echo "Invalid usb function none" >&2
    exit 1
   fi
   printf "%s" "${5:-}" > "\(usbStateFile.path)"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = "ip" ]; then
   exit 0
  fi
  exit 0
  """
  try adbScript.write(to:adbURL,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adbURL.path)
  let stateDir=tempDir.appendingPathComponent("state")
  try FileManager.default.createDirectory(at:stateDir,withIntermediateDirectories:true)
  let journalURL=stateDir.appendingPathComponent("owned-sessions.json")
  let journalJSON="""
  [{"id":"\(sessionID)","serial":"phone-serial-none","token":"0123456789abcdef0123456789abcdef","oldUSB":"none","ncmUSBChanged":true,"module":"phoneInternet"}]
  """
  try journalJSON.write(to:journalURL,atomically:true,encoding:.utf8)
  let controller=SessionController(resourceRoot:tempDir,stateDirectory:stateDir)
  controller.boot()
  for _ in 0..<140 {
   if !controller.snapshot.recoveryMessage.isEmpty { break }
   try await Task.sleep(nanoseconds:50_000_000)
  }
  var wifiSettings=Settings()
  wifiSettings.transport = .wifi
  controller.send(.saveSettings(wifiSettings))
  for _ in 0..<140 {
   if !controller.snapshot.isSavingSettings { break }
   try await Task.sleep(nanoseconds:50_000_000)
  }
  defer { Task { @MainActor in _ = await controller.shutdown(timeout:0.2) } }
  XCTAssertFalse(controller.snapshot.isSavingSettings)
  XCTAssertEqual(controller.snapshot.settingsMessage,"设置已保存，请点击开始重新连接","Saving settings must succeed instead of failing with '停止未完成，设置未保存；请重试全部停止' when oldUSB is 'none'")
  XCTAssertEqual(controller.snapshot.settings.transport,.wifi,"Settings must be persisted after cleaning up phoneInternet with oldUSB='none'")
 }
 func testWifiAudioReceiverAcceptsDifferentClientAudioParametersAndDefaultListenAddress() async throws {
  final class Box: @unchecked Sendable {
   private let lock=NSLock()
   private var frames=[Data]()
   private var error:String?
   private var negotiated:AudioParameters?
   private var fulfilled=false
   func append(_ batch:[Data]) { lock.lock(); frames.append(contentsOf:batch); lock.unlock() }
   func setError(_ err:String) { lock.lock(); if error == nil { error=err }; lock.unlock() }
   func setNegotiated(_ params:AudioParameters) { lock.lock(); negotiated=params; lock.unlock() }
   func claimFulfill() -> Bool { lock.lock(); defer { lock.unlock() }; if fulfilled { return false }; fulfilled=true; return true }
   func snapshot() -> (frames:[Data],error:String?,negotiated:AudioParameters?) { lock.lock(); defer { lock.unlock() }; return (frames,error,negotiated) }
  }
  let box=Box()
  let receiver=AudioReceiver()
  defer { receiver.stop() }
  var macSettings=Settings()
  macSettings.transport = .wifi
  macSettings.listenAddress = "127.0.0.1"
  macSettings.audioPort = Int.random(in: 49200...58999)
  macSettings.pairingCode = ""
  macSettings.audio.sampleRate = 48000
  macSettings.audio.channels = 2
  macSettings.audio.format = .f32
  macSettings.audio.source = .microphone

  let playback=PCMPlaybackBuffer(capacity:48000*2,channels:2,maximumBufferedFrames:4800)
  let outputInput=AudioOutputInput(playback:playback,parameters:macSettings.audio)

  let receivedExpectation=expectation(description:"received Wi-Fi PCM batch")
  try receiver.start(
   settings:macSettings,
   session:"wifi",
   onHandshake:{ clientAudio in
    box.setNegotiated(clientAudio)
    outputInput.updateSourceParameters(clientAudio)
   },
   onBatch:{ frames,ack in
    do {
     for frame in frames {
      _ = try outputInput.consume(frame, measure: true)
     }
     box.append(frames)
    } catch {
     box.setError(error.localizedDescription)
    }
    ack()
    if box.claimFulfill() { receivedExpectation.fulfill() }
   },
   onError:{ err in
    box.setError(err)
    if box.claimFulfill() { receivedExpectation.fulfill() }
   }
  )
  try await Task.sleep(nanoseconds:100_000_000)
  let clientScript="""
  import socket, struct, json, sys, time
  port = int(sys.argv[1])
  s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
  hs = {"protocol": 4, "session": "wifi", "token": "", "sampleRate": 44100, "channels": 1, "format": "i16", "source": "microphone"}
  s.sendall((json.dumps(hs) + "\\n").encode("utf-8"))
  pcm = b"\\x00\\x10" * 160
  s.sendall(struct.pack(">I", len(pcm)) + pcm)
  time.sleep(0.15)
  s.close()
  """
  _ = try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/python3"),["-c",clientScript,"\(macSettings.audioPort)"],timeout:3)
  await fulfillment(of:[receivedExpectation],timeout:3.0)
  let snap=box.snapshot()
  XCTAssertFalse(snap.frames.isEmpty,"Wi-Fi receiver must deliver PCM frames from phone (error=\(snap.error ?? "none"))")
  XCTAssertEqual(snap.negotiated?.sampleRate,44100)
  XCTAssertEqual(snap.negotiated?.channels,1)
  XCTAssertEqual(snap.negotiated?.format,.i16)
  XCTAssertGreaterThan(playback.statistics.enqueuedFrames,0,"AudioOutputInput must convert phone 44.1kHz mono i16 into Mac 48kHz stereo f32 playback buffer")
 }
 @MainActor func testAudioOutputRestartCurrentDevicePreservesInputHandle() throws {
  let output=AudioOutput()
  defer { output.stop() }
  var settings=Settings()
  settings.outputUID="default"
  settings.muted=true
  try output.start(settings)
  let input=try output.makeInput()
  var restartCalls=0
  output.onRestartCurrentDevice = { restartCalls += 1 }
  try output.restartCurrentDevice(settings)
  XCTAssertEqual(restartCalls,1)
  let pcm=Data(repeating:0,count:320)
  _ = try input.consume(pcm,measure:false)
  XCTAssertGreaterThan(output.statistics.enqueuedFrames,0,"Existing AudioOutputInput must remain valid after in-place output restart")
 }
}
