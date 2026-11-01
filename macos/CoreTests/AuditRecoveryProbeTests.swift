import XCTest
import Foundation
import Contracts
@testable import Core

final class AuditRecoveryProbeTests: XCTestCase {
 @MainActor func testFailedRecoveryMustNotPollHistoricalAudioSession() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-audit-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let adb = root.appendingPathComponent("platform-tools/adb")
  let state = root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
  try "#!/bin/sh\necho \"error: device not found\" >&2\nexit 1\n".write(to: adb, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
  let journal = """
  [{"id":"audit-old-session","serial":"audit-fake-device","token":"audit-fake-token","controlForward":59187,"controlTarget":48125,"module":"microphone"}]
  """
  try journal.write(to: state.appendingPathComponent("owned-sessions.json"), atomically: true, encoding: .utf8)
  let controller = SessionController(resourceRoot: root, stateDirectory: state)
  controller.boot()
  try await Task.sleep(nanoseconds: 5_000_000_000)
  let logs = controller.snapshot.logs
  _ = await controller.shutdown(timeout: 1)
  XCTAssertTrue(logs.contains { $0.stage == "上次资源恢复待重试，请点击全部停止" }, "Probe must reach failed recovery")
  let polls = logs.filter { $0.stage == "controlObservationFailed" }
  print("AUDIT historical-session control polls after failed recovery: \(polls.count)")
  XCTAssertTrue(polls.isEmpty, "Historical cleanup record must not be polled as a live microphone session")
 }

 @MainActor func testFailedStopCleanupDoesNotTriggerOutputStalledOrRepeatStop() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-stop-stall-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let adb = root.appendingPathComponent("platform-tools/adb")
  let state = root.appendingPathComponent("state")
  let onlineFlag = root.appendingPathComponent("device-online")
  try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
  try "1".write(to: onlineFlag, atomically: true, encoding: .utf8)

  let audioPort = Int.random(in: 49300...58900)
  let controlPort = audioPort + 1
  let controlServerPortFile = root.appendingPathComponent("control-port.txt")

  // Start a tiny Python control server that responds to status/stop until device-online is removed
  let controlServerScript = """
  import socket, json, sys, os
  srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  srv.bind(("127.0.0.1", 0))
  srv.listen(16)
  with open(sys.argv[1], "w") as f:
      f.write(str(srv.getsockname()[1]))
  while True:
      try:
          conn, _ = srv.accept()
          data = conn.recv(4096).decode("utf-8", errors="ignore").strip()
          req = json.loads(data) if data else {}
          reply = {
              "protocol": 4,
              "controlRevision": 1,
              "session": req.get("session", ""),
              "accepted": True,
              "cancelled": False,
              "cancelAccepted": False,
              "producerStopped": False,
              "recording": True,
              "microphonePermission": "allowed",
              "notificationPermission": "allowed",
              "vpnPermission": "notRequested",
              "network": "preparing",
              "error": ""
          }
          conn.sendall((json.dumps(reply) + "\\n").encode("utf-8"))
          conn.close()
      except Exception:
          break
  """
  let controlProcess = Process()
  controlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  controlProcess.arguments = ["-c", controlServerScript, controlServerPortFile.path]
  try controlProcess.run()
  defer { controlProcess.terminate() }

  for _ in 0..<40 {
   if FileManager.default.fileExists(atPath: controlServerPortFile.path) { break }
   try await Task.sleep(nanoseconds: 25_000_000)
  }
  let fakeControlPort = try String(contentsOf: controlServerPortFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

  let adbScript = """
  #!/bin/sh
  ONLINE_FILE="\(onlineFlag.path)"
  if [ "$1" = "devices" ]; then
   echo "List of devices attached"
   if [ -f "$ONLINE_FILE" ]; then
    echo "phone-stall-1\tdevice product:pixel model:Pixel_9"
   fi
   exit 0
  fi
  if [ "$1" = "forward" ] && [ "$2" = "--list" ]; then
   echo "phone-stall-1 tcp:\(fakeControlPort) tcp:\(controlPort)"
   exit 0
  fi
  if [ "$1" = "reverse" ] && [ "$2" = "--list" ]; then
   exit 0
  fi
  if [ ! -f "$ONLINE_FILE" ]; then
   echo "adb: error: device 'phone-stall-1' not found" >&2
   exit 1
  fi
  if [ "$1" = "-s" ]; then
   shift 2
  fi
  if [ "$1" = "get-state" ]; then
   echo "device"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = "pm" ] && [ "$3" = "list" ]; then
   echo "package:com.zjx.usblinkmic"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = "content" ]; then
   echo "Row: 0 {protocol=\(Capabilities.protocolVersion), controlRevision=\(Capabilities.controlRevision), runtimeRevision=\(Capabilities.runtimeRevision), controlComponent=\(Capabilities.androidControlComponent), versionName=\(Capabilities.version)}"
   exit 0
  fi
  if [ "$1" = "forward" ] && [ "$2" = "tcp:0" ]; then
   echo "\(fakeControlPort)"
   exit 0
  fi
  exit 0
  """
  try adbScript.write(to: adb, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)

  var settings = Settings()
  settings.transport = .usb
  settings.purpose = .monitor
  settings.outputUID = "default"
  settings.muted = true
  settings.audioPort = audioPort
  settings.controlPort = controlPort
  try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("settings.json"), options: .atomic)

  let controller = SessionController(resourceRoot: root, stateDirectory: state)
  controller.boot()

  // Wait for device discovery
  for _ in 0..<60 {
   if controller.snapshot.selectedDeviceID == "phone-stall-1" { break }
   try await Task.sleep(nanoseconds: 50_000_000)
  }
  XCTAssertEqual(controller.snapshot.selectedDeviceID, "phone-stall-1")

  controller.send(.start(.microphone))
  // Wait for receiver port to open and controlForward to be written in session journal
  var sessionID = ""
  var sessionToken = ""
  let journalURL = state.appendingPathComponent("owned-sessions.json")
  for _ in 0..<80 {
   if let data = try? Data(contentsOf: journalURL),
      let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
      let first = list.first,
      let id = first["id"] as? String,
      let tok = first["token"] as? String,
      first["controlForward"] != nil {
    sessionID = id
    sessionToken = tok
    break
   }
   try await Task.sleep(nanoseconds: 50_000_000)
  }
  XCTAssertFalse(sessionID.isEmpty, "Session journal must be written when USB microphone starts")

  // Connect a simulated phone audio stream in background so audioPacketCount > 0 and streaming is active
  let streamScript = """
  import socket, struct, json, sys, time
  port = int(sys.argv[1])
  session = sys.argv[2]
  token = sys.argv[3]
  s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
  hs = {"protocol": 4, "session": session, "token": token, "sampleRate": 44100, "channels": 1, "format": "i16", "source": "microphone"}
  s.sendall((json.dumps(hs) + "\\n").encode("utf-8"))
  reply = s.recv(1024)
  pcm = b"\\x10\\x00" * 441
  while True:
      try:
          s.sendall(struct.pack(">I", len(pcm)) + pcm)
          time.sleep(0.02)
      except Exception:
          break
  """
  let streamProcess = Process()
  streamProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  streamProcess.arguments = ["-c", streamScript, "\(audioPort)", sessionID, sessionToken]
  try streamProcess.run()
  defer { streamProcess.terminate() }

  for _ in 0..<60 {
   if controller.telemetry.receivedFrames > 0 { break }
   try await Task.sleep(nanoseconds: 50_000_000)
  }
  XCTAssertGreaterThan(controller.telemetry.receivedFrames, 0, "Audio frames must be received before disconnect")

  // Now simulate USB disconnect and stop microphone so cleanup fails and leaves owned[.microphone] in journal
  try? FileManager.default.removeItem(at: onlineFlag)
  controlProcess.terminate()
  streamProcess.terminate()

  controller.send(.stop(.microphone))
  for _ in 0..<80 {
   if controller.snapshot.microphone.phase == .failed && controller.snapshot.microphone.errorCode == "CLEANUP_INCOMPLETE" {
    break
   }
   try await Task.sleep(nanoseconds: 50_000_000)
  }
  XCTAssertEqual(controller.snapshot.microphone.phase, .failed)
  XCTAssertEqual(controller.snapshot.microphone.errorCode, "CLEANUP_INCOMPLETE")

  let sessionEndCountAfterStop = controller.snapshot.logs.filter { $0.stage == "sessionEnd" }.count
  XCTAssertEqual(sessionEndCountAfterStop, 1, "Active session stop must log sessionEnd exactly once")

  // Wait 4.2 seconds (past the 3.0s OUTPUT_STALLED threshold and 4 tick() cycles)
  try await Task.sleep(nanoseconds: 4_200_000_000)
  let logsAfterWait = controller.snapshot.logs
  _ = await controller.shutdown(timeout: 0.5)

  let outputStalledLogs = logsAfterWait.filter { $0.message.contains("OUTPUT_STALLED") }
  XCTAssertTrue(outputStalledLogs.isEmpty, "Stopped session awaiting cleanup must never trigger OUTPUT_STALLED")
  let sessionEndCountAfterWait = logsAfterWait.filter { $0.stage == "sessionEnd" }.count
  XCTAssertEqual(sessionEndCountAfterWait, 1, "Failed cleanup must not repeatedly re-trigger stop/sessionEnd")
 }

 @MainActor func testScopedSaveSettingsDoesNotBlockDNSOnVirtualMicOrStopUnrelatedMicrophone() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-scoped-save-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let adb = root.appendingPathComponent("platform-tools/adb")
  let state = root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
  try "#!/bin/sh\necho \"List of devices attached\"\nexit 0\n".write(to: adb, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)

  // Save initial settings where purpose is virtualMicrophone and outputUID is a missing BlackHole device
  var initial = Settings()
  initial.purpose = .virtualMicrophone
  initial.outputUID = "missing-blackhole-uid"
  initial.dns = "1.1.1.1"
  let data = try JSONEncoder().encode(initial)
  try data.write(to: state.appendingPathComponent("settings.json"), options: .atomic)

  let controller = SessionController(resourceRoot: root, stateDirectory: state)
  let initialRev = controller.snapshot.settingsSavedRevision

  // 1. Changing DNS only (affecting macInternet) must NOT be blocked by missing BlackHole
  var dnsEdit = controller.snapshot.settings
  dnsEdit.dns = "8.8.8.8"
  controller.send(.saveSettings(dnsEdit))
  for _ in 0..<40 {
   if !controller.snapshot.isSavingSettings && controller.snapshot.settings.dns == "8.8.8.8" { break }
   try await Task.sleep(nanoseconds: 25_000_000)
  }
  XCTAssertEqual(controller.snapshot.settings.dns, "8.8.8.8")
  XCTAssertNil(controller.snapshot.settingsError)
  XCTAssertGreaterThan(controller.snapshot.settingsSavedRevision, initialRev)

  // 2. Changing gain/muted only applies immediately in-place without async stop
  let revBeforeGain = controller.snapshot.settingsSavedRevision
  var gainEdit = controller.snapshot.settings
  gainEdit.gain = 1.75
  gainEdit.muted = true
  controller.send(.saveSettings(gainEdit))
  XCTAssertFalse(controller.snapshot.isSavingSettings)
  XCTAssertEqual(controller.snapshot.settings.gain, 1.75)
  XCTAssertTrue(controller.snapshot.settings.muted)
  XCTAssertNil(controller.snapshot.settingsError)
  XCTAssertGreaterThan(controller.snapshot.settingsSavedRevision, revBeforeGain)
 }

 @MainActor func testAudioOutputDeviceCacheAndObserverHandleUnplug() async throws {
  defer {
   AudioOutput.devicesProvider = nil
   AudioOutput.defaultOutputUIDProvider = nil
   AudioOutput.invalidateDeviceCache()
  }
  let speaker = OutputDevice(id: "builtin-speaker", name: "MacBook Pro Speakers", isVirtual: false)
  let usbHeadset = OutputDevice(id: "usb-headset", name: "USB Headset", isVirtual: false)
  nonisolated(unsafe) var currentDevices = [speaker, usbHeadset]
  AudioOutput.invalidateDeviceCache()
  AudioOutput.enumerationCount = 0
  AudioOutput.devicesProvider = { currentDevices }
  AudioOutput.defaultOutputUIDProvider = { "builtin-speaker" }

  let first = AudioOutput.devices()
  let second = AudioOutput.devices()
  XCTAssertEqual(first, [speaker, usbHeadset])
  XCTAssertEqual(second, [speaker, usbHeadset])
  XCTAssertEqual(AudioOutput.enumerationCount, 1, "Cached AudioOutput.devices() must not re-enumerate hardware when forceRefresh is false")

  let refreshed = AudioOutput.devices(forceRefresh: true)
  XCTAssertEqual(refreshed.count, 2)
  XCTAssertEqual(AudioOutput.enumerationCount, 2)

  let root = FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-dev-cache-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let state = root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

  var settings = Settings()
  settings.outputUID = "usb-headset"
  try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("settings.json"), options: .atomic)

  let controller = SessionController(resourceRoot: root, stateDirectory: state)
  XCTAssertEqual(controller.snapshot.outputs, [speaker, usbHeadset])

  // Simulate USB headset unplug followed by reconnect
  currentDevices = [speaker]
  controller.handleAudioDeviceSnapshot(AudioDeviceSnapshot(devices: currentDevices, defaultOutputUID: "builtin-speaker"))
  XCTAssertEqual(controller.snapshot.outputs, [speaker])
  XCTAssertTrue(controller.snapshot.logs.contains { $0.stage == "outputsChanged" })
 }

 func testWifiTargetHostResolutionPrefersConfiguredHostAndRejectsLoopbackOrVPN() {
  let interfaces = [
   NetworkInterface(name: "en0", address: "192.168.1.25"),
   NetworkInterface(name: "en5", address: "192.168.50.10"),
   NetworkInterface(name: "en7", address: "172.16.42.2")
  ]
  let explicit = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "192.168.50.10",
   interfaces: interfaces,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "0.0.0.0"
  )
  XCTAssertEqual(explicit.host, "192.168.50.10", "Explicit valid active user-configured wifiHost must take priority over auto-detected order")
  XCTAssertTrue(explicit.isUserSpecified)
  XCTAssertFalse(explicit.isAmbiguous)
  XCTAssertNil(explicit.errorCode)

  // Stale/non-local wifiHost under 0.0.0.0 must be rejected rather than synced to phone
  let staleTarget = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "192.168.1.99",
   interfaces: interfaces,
   activeInterfaces: ["en0"],
   excludedInterfaces: ["en7"],
   listenAddress: "0.0.0.0"
  )
  XCTAssertNil(staleTarget.host)
  XCTAssertEqual(staleTarget.errorCode, "WIFI_TARGET_UNAVAILABLE")

  let loopbackFallback = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "127.0.0.1",
   interfaces: interfaces,
   activeInterfaces: ["en0"],
   excludedInterfaces: ["en7"],
   listenAddress: "127.0.0.1"
  )
  XCTAssertEqual(loopbackFallback.host, "192.168.1.25", "Loopback must never be selected as phone Wi-Fi target host")
  XCTAssertFalse(loopbackFallback.isUserSpecified)
  XCTAssertFalse(loopbackFallback.isAmbiguous)
  XCTAssertNil(loopbackFallback.errorCode)

  let vpnFallback = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "10.0.0.2",
   interfaces: interfaces,
   activeInterfaces: ["en0"],
   excludedInterfaces: ["en7"],
   listenAddress: "0.0.0.0"
  )
  XCTAssertEqual(vpnFallback.host, "192.168.1.25", "Internal VPN address 10.0.0.2 must never be selected as phone Wi-Fi target host")
  XCTAssertFalse(vpnFallback.isUserSpecified)
  XCTAssertFalse(vpnFallback.isAmbiguous)
  XCTAssertNil(vpnFallback.errorCode)

  // Inactive en0 + active en1 + active excluded USB NCM en7: selects active en1
  let inactivePlusUsbFixture = [
   NetworkInterface(name: "en0", address: "192.168.1.10"),
   NetworkInterface(name: "en1", address: "192.168.1.25"),
   NetworkInterface(name: "en7", address: "172.16.42.2")
  ]
  let singleActive = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "",
   interfaces: inactivePlusUsbFixture,
   activeInterfaces: ["en1", "en7"],
   excludedInterfaces: ["en7"],
   listenAddress: "0.0.0.0"
  )
  XCTAssertEqual(singleActive.host, "192.168.1.25", "Must skip inactive en0 and excluded USB en7 to select active en1")
  XCTAssertFalse(singleActive.isAmbiguous)
  XCTAssertEqual(singleActive.candidates.map(\.address), ["192.168.1.25"])
  XCTAssertNil(singleActive.errorCode)

  // Stale saved listenAddress on inactive en0 is rejected at resolution boundary
  let staleListen = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "",
   interfaces: inactivePlusUsbFixture,
   activeInterfaces: ["en1", "en7"],
   excludedInterfaces: ["en7"],
   listenAddress: "192.168.1.10"
  )
  XCTAssertNil(staleListen.host)
  XCTAssertEqual(staleListen.errorCode, "WIFI_LISTEN_ADDRESS_UNAVAILABLE")

  // Multiple active LAN interfaces without explicit user target must report ambiguity rather than guessing
  let multiActiveFixture = [
   NetworkInterface(name: "en0", address: "192.168.1.25"),
   NetworkInterface(name: "en5", address: "192.168.50.10"),
   NetworkInterface(name: "en7", address: "172.16.42.2")
  ]
  let ambiguous = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5", "en7"],
   excludedInterfaces: ["en7"],
   listenAddress: "0.0.0.0"
  )
  XCTAssertNil(ambiguous.host, "Multiple active LAN interfaces must not silently guess the first interface")
  XCTAssertTrue(ambiguous.isAmbiguous)
  XCTAssertEqual(ambiguous.candidates.map(\.address), ["192.168.1.25", "192.168.50.10"])
  XCTAssertNil(ambiguous.errorCode)

  // Explicit listenAddress derives phone target when wifiHost is empty
  let disambiguatedByListen = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "192.168.50.10"
  )
  XCTAssertEqual(disambiguatedByListen.host, "192.168.50.10")
  XCTAssertTrue(disambiguatedByListen.isUserSpecified)
  XCTAssertFalse(disambiguatedByListen.isAmbiguous)
  XCTAssertNil(disambiguatedByListen.errorCode)

  // Listen A / Target B mismatch is rejected with WIFI_ENDPOINT_MISMATCH
  let endpointMismatch = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "192.168.50.10",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "192.168.1.25"
  )
  XCTAssertNil(endpointMismatch.host)
  XCTAssertEqual(endpointMismatch.errorCode, "WIFI_ENDPOINT_MISMATCH")

  // Hostname resolution: single interface requires exact match {A}; rejects {A, B}, {B}, and empty
  let validHostname = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "macbook.local.",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "192.168.1.25",
   hostnameResolver: { _ in ["192.168.1.25"] }
  )
  XCTAssertEqual(validHostname.host, "macbook.local")
  XCTAssertTrue(validHostname.isUserSpecified)
  XCTAssertNil(validHostname.errorCode)

  let multiAddressHostname = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "macbook.local",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "192.168.1.25",
   hostnameResolver: { _ in ["192.168.1.25", "192.168.50.10"] }
  )
  XCTAssertNil(multiAddressHostname.host)
  XCTAssertEqual(multiAddressHostname.errorCode, "WIFI_HOSTNAME_MULTI_ADDRESS")

  let mismatchedHostname = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "macbook.local",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "192.168.1.25",
   hostnameResolver: { _ in ["192.168.50.10"] }
  )
  XCTAssertNil(mismatchedHostname.host)
  XCTAssertEqual(mismatchedHostname.errorCode, "WIFI_HOSTNAME_MISMATCH")

  let emptyHostname = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "macbook.local",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "192.168.1.25",
   hostnameResolver: { _ in [] }
  )
  XCTAssertNil(emptyHostname.host)
  XCTAssertEqual(emptyHostname.errorCode, "WIFI_HOSTNAME_UNAVAILABLE")

  // Hostname resolution under 0.0.0.0: all resolved addresses must belong to active local LAN
  let allLocalMultiHostname = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "macbook.local",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "0.0.0.0",
   hostnameResolver: { _ in ["192.168.1.25", "192.168.50.10"] }
  )
  XCTAssertEqual(allLocalMultiHostname.host, "macbook.local")
  XCTAssertNil(allLocalMultiHostname.errorCode)

  let notAllLocalHostname = NetworkProbe.resolveWifiTargetHost(
   configuredHost: "macbook.local",
   interfaces: multiActiveFixture,
   activeInterfaces: ["en0", "en5"],
   excludedInterfaces: ["en7"],
   listenAddress: "0.0.0.0",
   hostnameResolver: { _ in ["192.168.1.25", "198.51.100.1"] }
  )
  XCTAssertNil(notAllLocalHostname.host)
  XCTAssertEqual(notAllLocalHostname.errorCode, "WIFI_HOSTNAME_NOT_ALL_LOCAL")
 }

 func testProcessRunnerAndADBClassifyDistinguishNormalExit6FromSIGABRTAndDaemonText() async throws {
  // 1. Ordinary process exiting with status 6 must NOT be classified as daemon crash
  let normalExit6 = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo 'ordinary command failure' >&2; exit 6"], timeout: 2.0)
  XCTAssertEqual(normalExit6.code, 6)
  XCTAssertEqual(normalExit6.terminationReason, ProcessTerminationReason.exit)
  XCTAssertNil(normalExit6.terminationSignal)
  XCTAssertEqual(
   ADB.classify(normalExit6),
   "ADB_FAILED",
   "Normal exit status 6 without daemon error text must not be misattributed to ADB_DAEMON_START_FAILED"
  )

  // 2. Client process killed by SIGABRT without daemon text must be classified as ADB_PROCESS_ABORTED, not server crash
  let sigabrtResult = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-c", "import os; os.abort()"], timeout: 2.0)
  XCTAssertEqual(sigabrtResult.terminationReason, ProcessTerminationReason.uncaughtSignal)
  XCTAssertEqual(sigabrtResult.terminationSignal, SIGABRT)
  XCTAssertEqual(
   ADB.classify(sigabrtResult),
   "ADB_PROCESS_ABORTED",
   "Uncaught client SIGABRT without daemon text must report ADB_PROCESS_ABORTED"
  )

  // 3. Explicit daemon/connection failure text is classified as ADB_DAEMON_START_FAILED regardless of exit/signal
  XCTAssertEqual(
   ADB.classify("failed to check server version: cannot connect to daemon", exitCode: 134, terminationReason: .uncaughtSignal, terminationSignal: SIGABRT),
   "ADB_DAEMON_START_FAILED"
  )
  XCTAssertEqual(
   ADB.classify("adb: failed to read response from server: Connection reset by peer", exitCode: 1, terminationReason: .exit),
   "ADB_DAEMON_START_FAILED"
  )
  XCTAssertEqual(
   ADB.classify("error writing ACK to fd: Broken pipe", exitCode: 6, terminationReason: .exit),
   "ADB_DAEMON_START_FAILED"
  )
 }

 func testAudioReceiverEffectiveBindAddressAcrossCustomLanUsbAndWifiSwitches() throws {
  let receiver = AudioReceiver()
  defer { receiver.stop() }
  let port = Int.random(in: 51000...57000)

  var settings = Settings()
  settings.audioPort = port
  settings.listenAddress = "192.168.1.25"
  settings.transport = .usb

  // Even when settings.listenAddress holds a custom Wi-Fi LAN IP, USB mode must bind 127.0.0.1
  XCTAssertEqual(AudioReceiver.effectiveBindAddress(for: settings), "127.0.0.1")
  try receiver.start(
   settings: settings,
   session: "usb-bind-test",
   onBatch: { _, done in done() },
   onError: { _ in }
  )
  XCTAssertEqual(receiver.boundAddress, "127.0.0.1")
  receiver.stop()

  // Switching back to Wi-Fi preserves the custom LAN IP
  settings.transport = .wifi
  XCTAssertEqual(AudioReceiver.effectiveBindAddress(for: settings), "192.168.1.25")

  // Legacy 127.0.0.1 in Wi-Fi mode migrates to 0.0.0.0
  settings.listenAddress = "127.0.0.1"
  XCTAssertEqual(AudioReceiver.effectiveBindAddress(for: settings), "0.0.0.0")
 }

 @MainActor func testAudioTelemetryDemandGatingStopsHighFrequencyPublishWhenHiddenAndSharesAcrossConsumers() {
  let telemetry = AudioTelemetry()
  let consumerA = UUID()
  let consumerB = UUID()
  let hiddenWindowState = TelemetryVisibilityState(
   hasWindow: true,
   isViewHidden: false,
   isWindowVisible: false,
   isWindowUnoccluded: false,
   isAppHidden: false
  )
  let visibleState = TelemetryVisibilityState(
   hasWindow: true,
   isViewHidden: false,
   isWindowVisible: true,
   isWindowUnoccluded: true,
   isAppHidden: false
  )
  let occludedState = TelemetryVisibilityState(
   hasWindow: true,
   isViewHidden: false,
   isWindowVisible: true,
   isWindowUnoccluded: false,
   isAppHidden: false
  )

  XCTAssertFalse(telemetry.hasActiveConsumers)
  XCTAssertEqual(telemetry.activeConsumerCount, 0)
  XCTAssertEqual(telemetry.registeredConsumerCount, 0)
  XCTAssertEqual(telemetry.publishCount, 0)

  // 1. Probe reports hidden BEFORE onAppear(registerConsumer): onAppear must NEVER override hidden state
  telemetry.reportConsumerVisibility(consumerA, state: hiddenWindowState)
  telemetry.registerConsumer(consumerA)
  XCTAssertEqual(telemetry.registeredConsumerCount, 1)
  XCTAssertFalse(telemetry.hasActiveConsumers, "registerConsumer (onAppear) must not activate a hidden consumer")
  for frame in 1...5 {
   telemetry.update(level: 0.42, waveform: [0.42], receivedFrames: UInt64(frame))
  }
  XCTAssertEqual(telemetry.receivedFrames, 5)
  XCTAssertEqual(telemetry.updateCount, 5)
  XCTAssertEqual(telemetry.publishCount, 0, "Hidden telemetry consumers must not trigger high-frequency SwiftUI publishes")

  // 2. Native probe reports visible -> consumerA becomes active and publishes
  telemetry.reportConsumerVisibility(consumerA, state: visibleState)
  XCTAssertTrue(telemetry.hasActiveConsumers)
  XCTAssertEqual(telemetry.activeConsumerCount, 1)
  let countAfterVisibleA = telemetry.publishCount

  telemetry.update(level: 0.55, waveform: [0.55], receivedFrames: 6)
  XCTAssertEqual(telemetry.publishCount, countAfterVisibleA + 1)

  // 3. Visible -> Occluded transition stops publishing; subsequent registerConsumer while occluded still stays inactive
  telemetry.reportConsumerVisibility(consumerA, state: occludedState)
  telemetry.registerConsumer(consumerA)
  XCTAssertFalse(telemetry.hasActiveConsumers)
  XCTAssertEqual(telemetry.activeConsumerCount, 0)
  let countAfterOccludedA = telemetry.publishCount
  telemetry.update(level: 0.60, waveform: [0.60], receivedFrames: 7)
  XCTAssertEqual(telemetry.publishCount, countAfterOccludedA, "Occluded window must not publish high-frequency telemetry")

  // 4. Multi-consumer sharing: A and B both visible; occluding A keeps B active
  telemetry.reportConsumerVisibility(consumerA, state: visibleState)
  telemetry.registerConsumer(consumerB)
  telemetry.reportConsumerVisibility(consumerB, state: visibleState)
  XCTAssertEqual(telemetry.registeredConsumerCount, 2)
  XCTAssertEqual(telemetry.activeConsumerCount, 2)

  telemetry.reportConsumerVisibility(consumerA, state: occludedState)
  XCTAssertTrue(telemetry.hasActiveConsumers)
  XCTAssertEqual(telemetry.activeConsumerCount, 1)

  let countWithBOnly = telemetry.publishCount
  telemetry.update(level: 0.65, waveform: [0.65], receivedFrames: 8)
  XCTAssertEqual(telemetry.publishCount, countWithBOnly + 1)

  // 5. Repeated appear/destroy (unregisterConsumer) cleans up both registered and active sets
  telemetry.unregisterConsumer(consumerA)
  telemetry.unregisterConsumer(consumerB)
  telemetry.unregisterConsumer(consumerB)
  XCTAssertFalse(telemetry.hasActiveConsumers)
  XCTAssertEqual(telemetry.activeConsumerCount, 0)
  XCTAssertEqual(telemetry.registeredConsumerCount, 0)
  let countAfterAllDestroyed = telemetry.publishCount

  for frame in 9...12 {
   telemetry.update(level: 0.75, waveform: [0.75], receivedFrames: UInt64(frame))
  }
  XCTAssertEqual(telemetry.receivedFrames, 12)
  XCTAssertEqual(telemetry.publishCount, countAfterAllDestroyed, "High-frequency publishing must stop once all consumers are unregistered")
  XCTAssertTrue(telemetry.diagnostics.contains("activeConsumers=0, registeredConsumers=0"))
 }

 @MainActor func testSaveWifiFieldsWhileUsbMicrophoneActiveDoesNotStopUsbSessionAndProgrammaticStopPreservesIntent() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-usb-wifi-save-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let adb = root.appendingPathComponent("platform-tools/adb")
  let state = root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

  let audioPort = Int.random(in: 49300...58900)
  let controlPort = audioPort + 1
  let controlServerPortFile = root.appendingPathComponent("control-port.txt")

  let controlServerScript = """
  import socket, json, sys
  srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  srv.bind(("127.0.0.1", 0))
  srv.listen(16)
  with open(sys.argv[1], "w") as f:
      f.write(str(srv.getsockname()[1]))
  while True:
      try:
          conn, _ = srv.accept()
          data = conn.recv(4096).decode("utf-8", errors="ignore").strip()
          req = json.loads(data) if data else {}
          is_stop = req.get("command") == "stop" or req.get("action") == "stop" or req.get("mode") == "stop"
          reply = {
              "protocol": 4,
              "controlRevision": 1,
              "session": req.get("session", ""),
              "accepted": True,
              "cancelled": is_stop,
              "cancelAccepted": is_stop,
              "producerStopped": is_stop,
              "recording": not is_stop,
              "microphonePermission": "allowed",
              "notificationPermission": "allowed",
              "vpnPermission": "notRequested",
              "network": "preparing",
              "error": ""
          }
          conn.sendall((json.dumps(reply) + "\\n").encode("utf-8"))
          conn.close()
      except Exception:
          break
  """
  let controlProcess = Process()
  controlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  controlProcess.arguments = ["-c", controlServerScript, controlServerPortFile.path]
  try controlProcess.run()
  defer { controlProcess.terminate() }

  for _ in 0..<40 {
   if FileManager.default.fileExists(atPath: controlServerPortFile.path) { break }
   try await Task.sleep(nanoseconds: 25_000_000)
  }
  let fakeControlPort = try String(contentsOf: controlServerPortFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

  let adbScript = """
  #!/bin/sh
  if [ "$1" = "devices" ]; then
   echo "List of devices attached"
   echo "phone-usb-1\tdevice product:pixel model:Pixel_9"
   exit 0
  fi
  if [ "$1" = "forward" ] && [ "$2" = "--list" ]; then
   echo "phone-usb-1 tcp:\(fakeControlPort) tcp:\(controlPort)"
   exit 0
  fi
  if [ "$1" = "reverse" ] && [ "$2" = "--list" ]; then
   exit 0
  fi
  if [ "$1" = "-s" ]; then
   shift 2
  fi
  if [ "$1" = "get-state" ]; then
   echo "device"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = "pm" ] && [ "$3" = "list" ]; then
   echo "package:com.zjx.usblinkmic"
   exit 0
  fi
  if [ "$1" = "shell" ] && [ "$2" = "content" ]; then
   echo "Row: 0 {protocol=\(Capabilities.protocolVersion), controlRevision=\(Capabilities.controlRevision), runtimeRevision=\(Capabilities.runtimeRevision), controlComponent=\(Capabilities.androidControlComponent), versionName=\(Capabilities.version)}"
   exit 0
  fi
  if [ "$1" = "forward" ] && [ "$2" = "tcp:0" ]; then
   echo "\(fakeControlPort)"
   exit 0
  fi
  exit 0
  """
  try adbScript.write(to: adb, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)

  var settings = Settings()
  settings.transport = .usb
  settings.purpose = .monitor
  settings.outputUID = "default"
  settings.muted = true
  settings.audioPort = audioPort
  settings.controlPort = controlPort
  try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("settings.json"), options: .atomic)

  let controller = SessionController(resourceRoot: root, stateDirectory: state)
  controller.boot()
  for _ in 0..<60 {
   if controller.snapshot.selectedDeviceID == "phone-usb-1" { break }
   try await Task.sleep(nanoseconds: 50_000_000)
  }

  controller.send(.start(.microphone))
  for _ in 0..<80 {
   if controller.activeSessions[.microphone] != nil &&
      (controller.snapshot.microphone.phase == .connecting || controller.snapshot.microphone.phase == .running) {
    break
   }
   try await Task.sleep(nanoseconds: 50_000_000)
  }
  let originalSessionID = controller.activeSessions[.microphone]
  let phaseBeforeSave = controller.snapshot.microphone.phase
  XCTAssertNotNil(originalSessionID)
  XCTAssertNotNil(controller.microphoneIntent, "User start must establish microphoneIntent")

  // Simulate user editing Wi-Fi fields in draft and switching back to USB before saving
  var wifiEdited = controller.snapshot.settings
  wifiEdited.transport = .usb
  wifiEdited.wifiHost = "192.168.1.77"
  wifiEdited.pairingCode = "00112233445566778899aabbccddeeff"
  wifiEdited.listenAddress = "192.168.1.25"
  controller.send(.saveSettings(wifiEdited))

  for _ in 0..<40 {
   if !controller.snapshot.isSavingSettings && controller.snapshot.settings.wifiHost == "192.168.1.77" { break }
   try await Task.sleep(nanoseconds: 25_000_000)
  }
  XCTAssertEqual(controller.snapshot.settings.wifiHost, "192.168.1.77")
  XCTAssertEqual(controller.snapshot.settings.pairingCode, "00112233445566778899aabbccddeeff")
  XCTAssertEqual(controller.activeSessions[.microphone], originalSessionID, "Saving Wi-Fi-only settings while USB microphone is running must NOT stop the active USB session")
  XCTAssertEqual(controller.snapshot.microphone.phase, phaseBeforeSave)

  // Verify programmatic stop (used by audioRecovery / USB NCM re-enumeration) preserves microphoneIntent
  await controller.stop(.microphone)
  for _ in 0..<80 {
   if controller.activeSessions[.microphone] == nil && controller.snapshot.microphone.phase == .stopped { break }
   try await Task.sleep(nanoseconds: 50_000_000)
  }
  XCTAssertNotNil(controller.microphoneIntent, "Programmatic stop(.microphone) must preserve microphoneIntent for recovery/re-enumeration")

  // Explicit user stop revokes microphoneIntent
  controller.send(.stop(.microphone))
  XCTAssertNil(controller.microphoneIntent, "User .stop(.microphone) must revoke microphoneIntent")
  _ = await controller.shutdown(timeout: 0.5)
 }

 @MainActor func testStartWifiAudioRejectsStaleListenAddressAtStartupBoundaryAndRedactsIP() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("usblinkmic-wifi-stale-start-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let adb = root.appendingPathComponent("platform-tools/adb")
  let state = root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
  try "#!/bin/sh\necho \"List of devices attached\"\nexit 0\n".write(to: adb, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)

  var settings = Settings()
  settings.transport = .wifi
  settings.purpose = .monitor
  settings.outputUID = "default"
  settings.muted = true
  settings.listenAddress = "198.51.100.42"
  settings.wifiHost = ""
  try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("settings.json"), options: .atomic)

  let controller = SessionController(resourceRoot: root, stateDirectory: state)
  controller.boot()
  for _ in 0..<60 {
   if !controller.recovering { break }
   try await Task.sleep(nanoseconds: 25_000_000)
  }

  controller.send(.start(.microphone))
  for _ in 0..<80 {
   if controller.snapshot.microphone.phase == .failed { break }
   try await Task.sleep(nanoseconds: 50_000_000)
  }

  XCTAssertEqual(controller.snapshot.microphone.phase, .failed)
  XCTAssertEqual(controller.snapshot.microphone.errorCode, "WIFI_LISTEN_ADDRESS_UNAVAILABLE")
  XCTAssertNil(controller.activeSessions[.microphone])
  let invalidLog = controller.snapshot.logs.first { $0.stage == "wifiEndpointInvalid" }
  XCTAssertNotNil(invalidLog, "Startup boundary rejection must record controlled wifiEndpointInvalid log entry")
  XCTAssertFalse(invalidLog?.message.contains("198.51.100.42") ?? true, "Diagnostic log must redact IPv4 addresses")
  XCTAssertTrue(invalidLog?.message.contains("[IP]") ?? false)
  _ = await controller.shutdown(timeout: 0.5)
 }
}
