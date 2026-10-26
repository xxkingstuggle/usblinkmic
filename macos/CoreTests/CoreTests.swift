import XCTest
import Foundation
@testable import Core
import Contracts
final class CoreTests:XCTestCase {
 func testMappingCleanupRequiresExactDeviceAndEndpoints(){
  let listing="phoneA tcp:12345 tcp:48125\nphoneB tcp:45678 tcp:48125\n"
  XCTAssertTrue(ADB.ownsMapping(listing,serial:"phoneA",local:"tcp:12345",remote:"tcp:48125"))
  XCTAssertFalse(ADB.ownsMapping(listing,serial:"phoneB",local:"tcp:12345",remote:"tcp:48125"))
  XCTAssertFalse(ADB.ownsMapping(listing,serial:"phoneA",local:"tcp:12345",remote:"tcp:9999"))
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
 @MainActor func testShutdownProceedsAndPreservesJournalWhenPhoneDisconnectedAfterControlTimeout() async throws {
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
  XCTAssertTrue(shouldTerminate,"Cmd+Q shutdown must allow termination even when phone is disconnected and cleanup fails")
  XCTAssertEqual(controller.snapshot.microphone.phase,.failed,"Must not claim cleanup succeeded when phone cancel failed")
  XCTAssertEqual(controller.snapshot.microphone.errorCode,"CLEANUP_INCOMPLETE")
  XCTAssertTrue(controller.snapshot.logs.contains(where:{$0.stage=="cancelControlPending"}),"Expected cancelControlPending log before fallback cancel")
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
  if [ "$1" = "forward" ] && [ "$2" = "--list" ]; then
   echo "phone-serial-2 tcp:\(closedPort) tcp:48125"
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
  try await Task.sleep(nanoseconds:100_000_000)
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
