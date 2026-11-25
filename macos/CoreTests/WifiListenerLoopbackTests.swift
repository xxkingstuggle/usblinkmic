import Network
import XCTest
import Contracts
import Support
@testable import Core

@MainActor private final class IdleHost: WifiSessionHost {
 func wifiPrepare(_ request: WifiPrepareRequest) async -> WifiPrepareResult { .rejected(code: "UNAVAILABLE") }
 func wifiEnd(sessionID: String, phoneID: String? = nil, reason: String) async {}
 func wifiPhase(sessionID: String) -> WifiSessionPhase { .ended }
 func wifiServiceChanged() {}
}

/// Minimal blocking-style TCP line client for the loopback listener.
private final class LineClient: @unchecked Sendable {
 let connection: NWConnection
 private var buffer = Data()
 init(port: UInt16) {
  connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
 }
 func open() async throws {
  final class ResumeGuard: @unchecked Sendable {
   private let lock = NSLock()
   private var resumed = false
   func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed else { return false }
    resumed = true
    return true
   }
  }
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
   let resumeGuard = ResumeGuard()
   let finish: @Sendable (Result<Void, Error>) -> Void = { result in
    guard resumeGuard.claim() else { return }
    continuation.resume(with: result)
   }
   connection.stateUpdateHandler = { state in
    switch state {
    case .ready: finish(.success(()))
    case .failed(let error): finish(.failure(error))
    case .waiting(let error): finish(.failure(error))
    default: break
    }
   }
   connection.start(queue: .global())
  }
 }
 func send(_ bytes: Data) { connection.send(content: bytes, completion: .contentProcessed { _ in }) }
 func send(_ object: [String: Any]) { send(try! JSONSerialization.data(withJSONObject: object) + Data([10])) }
 /// Next JSON line, or nil if the peer closed first.
 func readLine() async -> [String: Any]? {
  while true {
   if let newline = buffer.firstIndex(of: 10) {
    let line = buffer.prefix(upTo: newline)
    buffer = Data(buffer.suffix(from: buffer.index(after: newline)))
    return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
   }
   let chunk: Data? = await withCheckedContinuation { continuation in
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
     continuation.resume(returning: (error == nil && !(data?.isEmpty ?? true)) ? data : nil)
    }
   }
   guard let chunk else { return nil }
   buffer.append(chunk)
  }
 }
 func close() { connection.cancel() }
}

/// Uses a random loopback port with Bonjour advertising disabled: nothing leaves this Mac.
@MainActor final class WifiListenerLoopbackTests: XCTestCase {
 private var directory: URL!
 private var listener: WifiControlListener?
 private var service: WifiControlService!

 private func startListener() async throws -> UInt16 {
  directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-loopback-\(UUID().uuidString)")
  let trust = try WifiTrustStore(url: directory.appendingPathComponent("wifi-trust.json"))
  let host = IdleHost()
  hostRetainer = host
  service = WifiControlService(trust: trust, host: host, macName: "回环测试 Mac")
  let ready = expectation(description: "listener ready")
  let box = PortBox()
  let created = WifiControlListener(service: service, configuration: .init(macID: trust.macID, macName: "回环测试 Mac", advertise: false, loopbackOnly: true)) { state in
   if case .ready(let port, let advertised) = state { XCTAssertFalse(advertised); box.port = port; ready.fulfill() }
  }
  listener = created
  try created.start()
  await fulfillment(of: [ready], timeout: 5)
  return try XCTUnwrap(box.port)
 }
 private var hostRetainer: IdleHost?
 private final class PortBox: @unchecked Sendable { var port: UInt16? }

 override func tearDown() async throws {
  listener?.stop()
  if let directory { try? FileManager.default.removeItem(at: directory) }
 }

 func testHelloOverRealSocketAndUntrustedAuthIsRefused() async throws {
  let port = try await startListener()
  XCTAssertNotEqual(port, 48125, "never the loopback-only ADB control port")
  let client = LineClient(port: port)
  try await client.open()
  defer { client.close() }
  let cn = WifiCrypto.randomHex(byteCount: 16)
  client.send(["cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": Capabilities.runtimeRevision, "phoneID": "phone-loopback-1", "phoneName": "回环手机", "nonce": cn])
  let hello = await client.readLine()
  XCTAssertEqual(hello?["ok"] as? Bool, true)
  XCTAssertEqual(hello?["trusted"] as? Bool, false)
  XCTAssertEqual((hello?["nonce"] as? String)?.count, 32)
  client.send(["cmd": "auth", "proof": String(repeating: "0", count: 64)])
  let refused = await client.readLine()
  XCTAssertEqual(refused?["error"] as? String, "NOT_TRUSTED")
  let closed = await client.readLine()
  XCTAssertNil(closed, "the Mac closes the connection after refusing")
 }

 func testOldRuntimeIsToldItIsIncompatible() async throws {
  let port = try await startListener()
  let client = LineClient(port: port)
  try await client.open()
  defer { client.close() }
  client.send(["cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": 415, "phoneID": "phone-loopback-2", "nonce": WifiCrypto.randomHex(byteCount: 16)])
  let reply = await client.readLine()
  XCTAssertEqual(reply?["error"] as? String, "PROTOCOL_MISMATCH")
 }

 func testMalformedAndOversizedInputDropsTheConnectionWithoutAffectingOthers() async throws {
  let port = try await startListener()
  let bad = LineClient(port: port)
  try await bad.open()
  bad.send(Data("this is not json\n".utf8))
  let none = await bad.readLine()
  XCTAssertNil(none)
  bad.close()

  let big = LineClient(port: port)
  try await big.open()
  big.send(Data(repeating: 0x41, count: 6000))
  let dropped = await big.readLine()
  XCTAssertNil(dropped)
  big.close()

  let good = LineClient(port: port)
  try await good.open()
  defer { good.close() }
  good.send(["cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": 416, "phoneID": "phone-loopback-3", "nonce": WifiCrypto.randomHex(byteCount: 16)])
  let reply = await good.readLine()
  XCTAssertEqual(reply?["ok"] as? Bool, true)
 }

 func testStoppedListenerRefusesNewConnections() async throws {
  let port = try await startListener()
  listener?.stop()
  try await Task.sleep(nanoseconds: 300_000_000)
  let client = LineClient(port: port)
  do {
   try await client.open()
   client.send(["cmd": "hello"])
   let reply = await client.readLine()
   XCTAssertNil(reply)
  } catch {
   // refused outright is also correct
  }
  client.close()
 }

 func testWaitingDiscoveryStopPausesWifiAndRejectsLatePrepare() async throws {
  let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-boundary-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let trustURL = tempDir.appendingPathComponent("wifi-trust.json")
  let trustStore = try WifiTrustStore(url: trustURL)
  let phoneKeyBytes = (0..<32).map { UInt8($0) }
  let phoneKeyHex = phoneKeyBytes.map { String(format: "%02x", $0) }.joined()
  let phoneID = "phone-boundary-1"
  let phone = TrustedPhone(id: phoneID, name: "边界测试手机", keyHex: phoneKeyHex, pairedAt: Int64(Date().timeIntervalSince1970))
  try trustStore.upsert(phone)

  let controller = SessionController(resourceRoot: tempDir, stateDirectory: tempDir, wifiAutoConnect: true, wifiAdvertise: false)
  controller.boot()
  defer { Task { _ = await controller.shutdown(timeout: 1) } }

  var port: UInt16?
  for _ in 0..<50 {
   if let p = controller.wifiControlPort, p > 0 { port = p; break }
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  let boundPort = try XCTUnwrap(port)
  XCTAssertFalse(controller.snapshot.wifiAuto.pausedByUser)

  // User clicks stopAll BEFORE any phone connects
  controller.send(.stopAll, source: .ui)
  XCTAssertTrue(controller.snapshot.wifiAuto.pausedByUser)
  XCTAssertEqual(controller.snapshot.wifiAuto.phase, .paused)

  let client = LineClient(port: boundPort)
  try await client.open()
  defer { client.close() }

  let clientNonce = WifiCrypto.randomHex(byteCount: 16)
  client.send([
   "cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": Capabilities.runtimeRevision,
   "phoneID": phoneID, "phoneName": "边界测试手机", "nonce": clientNonce, "macID": trustStore.macID
  ])
  let helloRaw = await client.readLine()
  let hello = try XCTUnwrap(helloRaw)
  XCTAssertEqual(hello["ok"] as? Bool, true)
  let serverNonce = try XCTUnwrap(hello["nonce"] as? String)

  let phoneKey = try XCTUnwrap(WifiCrypto.bytes(fromHex: phoneKeyHex))
  let clientProof = WifiCrypto.authProof(key: phoneKey, fromServer: false, macID: trustStore.macID, phoneID: phoneID, clientNonce: clientNonce, serverNonce: serverNonce)
  client.send(["cmd": "auth", "proof": clientProof])
  let authRaw = await client.readLine()
  let auth = try XCTUnwrap(authRaw)
  XCTAssertEqual(auth["ok"] as? Bool, true)

  let fields = "44100|1|i16|microphone|0"
  let mac1 = WifiCrypto.messageMAC(key: phoneKey, direction: "c", clientNonce: clientNonce, serverNonce: serverNonce, sequence: 1, command: "prepare", fields: fields)
  client.send([
   "cmd": "prepare", "seq": 1, "sampleRate": 44100, "channels": 1,
   "format": "i16", "source": "microphone", "userInitiated": false, "mac": mac1
  ])

  let prepReplyRaw = await client.readLine()
  let prepReply = try XCTUnwrap(prepReplyRaw)
  XCTAssertEqual(prepReply["ok"] as? Bool, false)
  XCTAssertEqual(prepReply["code"] as? String, "PAUSED_BY_USER")
 }

 func testAudioReceiverIsReadyFollowsListenerLifetime() async throws {
  let receiver = AudioReceiver()
  XCTAssertFalse(receiver.isReady, "AudioReceiver must not be ready before start()")

  var settings = Settings()
  settings.transport = .usb
  settings.audioPort = Int.random(in: 49300...58900)

  try receiver.start(
   settings: settings,
   session: "receiver-lifecycle-\(UUID().uuidString)",
   onBatch: { _, done in done() },
   onError: { _ in }
  )

  var becameReady = false
  for _ in 0..<60 {
   if receiver.isReady { becameReady = true; break }
   try await Task.sleep(nanoseconds: 15_000_000)
  }
  XCTAssertTrue(becameReady, "AudioReceiver must report isReady == true once listener reaches ready")
  XCTAssertEqual(receiver.boundAddress, "127.0.0.1")

  receiver.stop()
  XCTAssertFalse(receiver.isReady, "AudioReceiver must report isReady == false after stop()")
 }

 func testStopAndRestartCancelsActiveConnectionsAndPreservesNextGenerationQuota() async throws {
  directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-restart-\(UUID().uuidString)")
  let trust = try WifiTrustStore(url: directory.appendingPathComponent("wifi-trust.json"))
  let host = IdleHost()
  hostRetainer = host
  service = WifiControlService(trust: trust, host: host, macName: "重连配额测试 Mac")

  final class StateCollector: @unchecked Sendable {
   private let lock = NSLock()
   private var readyPorts: [UInt16] = []
   func record(_ state: WifiListenerState) {
    if case .ready(let port, _) = state, port > 0 {
     lock.lock()
     readyPorts.append(port)
     lock.unlock()
    }
   }
   func port(at index: Int) -> UInt16? {
    lock.lock()
    defer { lock.unlock() }
    return index < readyPorts.count ? readyPorts[index] : nil
   }
  }

  let collector = StateCollector()
  let created = WifiControlListener(
   service: service,
   configuration: .init(macID: trust.macID, macName: "重连配额测试 Mac", advertise: false, loopbackOnly: true)
  ) { state in
   collector.record(state)
  }
  listener = created

  try created.start()
  var port1: UInt16?
  for _ in 0..<100 {
   if let p = collector.port(at: 0) { port1 = p; break }
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  let firstPort = try XCTUnwrap(port1)

  var gen1Clients: [LineClient] = []
  for index in 0..<WifiControlListener.maximumConnections {
   let client = LineClient(port: firstPort)
   try await client.open()
   client.send([
    "cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": Capabilities.runtimeRevision,
    "phoneID": "phone-gen1-\(index)", "phoneName": "Gen1-\(index)", "nonce": WifiCrypto.randomHex(byteCount: 16)
   ])
   let reply = await client.readLine()
   XCTAssertEqual(reply?["ok"] as? Bool, true)
   gen1Clients.append(client)
  }
  XCTAssertEqual(created.activeConnectionCount, WifiControlListener.maximumConnections)
  XCTAssertEqual(service.openConnectionCount, WifiControlListener.maximumConnections)

  // Stop while all slots are occupied: active connections must be cancelled immediately.
  created.stop()
  XCTAssertEqual(created.activeConnectionCount, 0)

  for client in gen1Clients {
   let eof = await client.readLine()
   XCTAssertNil(eof, "Stopping listener must terminate already-accepted client sockets")
  }
  for _ in 0..<50 where service.openConnectionCount > 0 {
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  XCTAssertEqual(service.openConnectionCount, 0, "Service must not retain any session after listener stop")

  // Start generation 2 and close gen1 client handles concurrently; full quota must be available.
  try created.start()
  var port2: UInt16?
  for _ in 0..<100 {
   if let p = collector.port(at: 1) { port2 = p; break }
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  let secondPort = try XCTUnwrap(port2)
  for client in gen1Clients { client.close() }

  var gen2Clients: [LineClient] = []
  defer { for client in gen2Clients { client.close() } }
  for index in 0..<WifiControlListener.maximumConnections {
   let client = LineClient(port: secondPort)
   try await client.open()
   client.send([
    "cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": Capabilities.runtimeRevision,
    "phoneID": "phone-gen2-\(index)", "phoneName": "Gen2-\(index)", "nonce": WifiCrypto.randomHex(byteCount: 16)
   ])
   let reply = await client.readLine()
   XCTAssertEqual(reply?["ok"] as? Bool, true, "Generation 2 connection #\(index) must not be rejected by stale counts")
   gen2Clients.append(client)
  }
  XCTAssertEqual(created.activeConnectionCount, WifiControlListener.maximumConnections)
  XCTAssertEqual(service.openConnectionCount, WifiControlListener.maximumConnections)

  for client in gen2Clients { client.close() }
  gen2Clients.removeAll()
  for _ in 0..<80 where created.activeConnectionCount > 0 || service.openConnectionCount > 0 {
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  XCTAssertEqual(created.activeConnectionCount, 0)
  XCTAssertEqual(service.openConnectionCount, 0)
 }

 func testAbortedEarlyConnectionsDoNotLeakServiceSessions() async throws {
  let port = try await startListener()
  let activeListener = try XCTUnwrap(listener)

  for _ in 0..<16 {
   let shortLived = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
   shortLived.start(queue: .global())
   try await Task.sleep(nanoseconds: 5_000_000)
   shortLived.cancel()
  }

  for _ in 0..<100 where activeListener.activeConnectionCount > 0 || service.openConnectionCount > 0 {
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  XCTAssertEqual(activeListener.activeConnectionCount, 0)
  XCTAssertEqual(service.openConnectionCount, 0, "Early-aborted TCP connections must never leak ghost WifiControlService sessions")

  let healthy = LineClient(port: port)
  try await healthy.open()
  defer { healthy.close() }
  healthy.send([
   "cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": Capabilities.runtimeRevision,
   "phoneID": "phone-after-abort", "phoneName": "恢复测试机", "nonce": WifiCrypto.randomHex(byteCount: 16)
  ])
  let reply = await healthy.readLine()
  XCTAssertEqual(reply?["ok"] as? Bool, true)
 }
}
