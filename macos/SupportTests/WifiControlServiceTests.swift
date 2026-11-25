import CryptoKit
import XCTest
import Contracts
@testable import Support

private final class FakeConn: WifiPeerConnection {
 var sent: [[String: Any]] = []
 var closed = false
 func send(_ object: [String: Any]) { sent.append(object) }
 func close() { closed = true }
 var last: [String: Any] { sent.last ?? [:] }
}

@MainActor private final class FakeHost: WifiSessionHost {
 var prepared: [WifiPrepareRequest] = []
 var ended: [(String, String)] = []
 var phases: [String: WifiSessionPhase] = [:]
 var changes = 0
 var nextResult: WifiPrepareResult = .ready(audioPort: 48124, audio: AudioParameters())
 var gate: CheckedContinuation<Void, Never>?
 var holdNextPrepare = false
 func wifiPrepare(_ request: WifiPrepareRequest) async -> WifiPrepareResult {
  prepared.append(request)
  phases[request.sessionID] = .preparing
  if holdNextPrepare {
   holdNextPrepare = false
   await withCheckedContinuation { gate = $0 }
  }
  return nextResult
 }
 func wifiEnd(sessionID: String, phoneID: String? = nil, reason: String) async { ended.append((sessionID, reason)); phases[sessionID] = .ended }
 func wifiPhase(sessionID: String) -> WifiSessionPhase { phases[sessionID] ?? .ended }
 func wifiServiceChanged() { changes += 1 }
}

/// Phone side of the protocol, written independently from the service under test.
private final class TestPhone {
 let id: String
 let name: String
 var key: Data?
 var cn = WifiCrypto.randomHex(byteCount: 16)
 var sn = ""
 var macID = ""
 var seq = 0
 var expectedServerSeq = 1
 init(id: String = WifiCrypto.randomHex(byteCount: 8), name: String = "测试手机", key: Data? = nil) { self.id = id; self.name = name; self.key = key }
 /// Same device identity and key, independent connection state.
 func clone() -> TestPhone { TestPhone(id: id, name: name, key: key) }

 func hello(runtimeRevision: Int = Capabilities.runtimeRevision, expectMac: String? = nil) -> [String: Any] {
  cn = WifiCrypto.randomHex(byteCount: 16); seq = 0; expectedServerSeq = 1
  var m: [String: Any] = ["cmd": "hello", "protocol": 4, "wifi": 1, "runtimeRevision": runtimeRevision, "phoneID": id, "phoneName": name, "nonce": cn]
  if let expectMac { m["macID"] = expectMac }
  return m
 }
 func authMessage(from reply: [String: Any]) -> [String: Any] {
  sn = reply["nonce"] as! String; macID = reply["macID"] as! String
  return ["cmd": "auth", "proof": WifiCrypto.authProof(key: key!, fromServer: false, macID: macID, phoneID: id, clientNonce: cn, serverNonce: sn)]
 }
 func serverProofValid(_ reply: [String: Any]) -> Bool {
  WifiCrypto.equal(reply["proof"] as? String ?? "", WifiCrypto.authProof(key: key!, fromServer: true, macID: macID, phoneID: id, clientNonce: cn, serverNonce: sn))
 }
 func signed(_ command: String, fields: String, body: [String: Any]) -> [String: Any] {
  seq += 1
  var m = body
  m["cmd"] = command; m["seq"] = seq
  m["mac"] = WifiCrypto.messageMAC(key: key!, direction: "c", clientNonce: cn, serverNonce: sn, sequence: seq, command: command, fields: fields)
  return m
 }
 func prepare(rate: Int = 48000, userInitiated: Bool = false) -> [String: Any] {
  signed("prepare", fields: "\(rate)|1|i16|microphone|\(userInitiated ? 1 : 0)", body: ["sampleRate": rate, "channels": 1, "format": "i16", "source": "microphone", "userInitiated": userInitiated])
 }
 func status() -> [String: Any] { signed("status", fields: "", body: [:]) }
 func stop(_ session: String) -> [String: Any] { signed("stop", fields: "\(session)|user", body: ["session": session, "reason": "user"]) }
 func serverMessageValid(_ m: [String: Any], fields: String) -> Bool {
  defer { expectedServerSeq += 1 }
  guard m["seq"] as? Int == expectedServerSeq, let cmd = m["cmd"] as? String else { return false }
  return WifiCrypto.equal(m["mac"] as? String ?? "", WifiCrypto.messageMAC(key: key!, direction: "s", clientNonce: cn, serverNonce: sn, sequence: expectedServerSeq, command: cmd, fields: fields))
 }
}

@MainActor final class WifiControlServiceTests: XCTestCase {
 private var directory: URL!
 private var trust: WifiTrustStore!
 private var host: FakeHost!
 private var service: WifiControlService!
 private var now = Date(timeIntervalSince1970: 1_800_000_000)

 override func setUpWithError() throws {
  directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-control-\(UUID().uuidString)")
  trust = try WifiTrustStore(url: directory.appendingPathComponent("wifi-trust.json"))
  host = FakeHost()
  service = WifiControlService(trust: trust, host: host, macName: "测试 Mac", clock: { [unowned self] in self.now })
 }
 override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

 private func open() -> (FakeConn, UUID) {
  let c = FakeConn()
  return (c, service.connectionOpened(c))
 }

 /// Pairs a fresh phone through the real message flow and returns it with its key.
 private func pairedPhone(name: String = "测试手机") async throws -> TestPhone {
  let phone = TestPhone(name: name)
  let (conn, id) = open()
  await service.receive(phone.hello(), on: id)
  let phoneKeys = WifiCrypto.PairingKeys()
  phone.sn = conn.last["nonce"] as! String
  phone.macID = conn.last["macID"] as! String
  await service.receive(["cmd": "pair", "pub": phoneKeys.publicBase64], on: id)
  let macPub = conn.last["macPub"] as! String
  let requestID = conn.last["requestID"] as! String
  let key = try XCTUnwrap(WifiCrypto.pairingKey(privateKey: phoneKeys.privateKey, peerPublicBase64: macPub, macID: phone.macID, phoneID: phone.id, clientNonce: phone.cn, serverNonce: phone.sn, phonePublicBase64: phoneKeys.publicBase64, macPublicBase64: macPub))
  XCTAssertEqual(service.pendingPrompt?.code, WifiCrypto.verificationCode(pairingKey: key), "both devices must display the same code")
  XCTAssertTrue(service.approvePair(requestID: requestID))
  await service.receive(["cmd": "pairStatus"], on: id)
  XCTAssertEqual(conn.last["status"] as? String, "approved")
  XCTAssertEqual(conn.last["proof"] as? String, WifiCrypto.pairApprovedProof(pairingKey: key, requestID: requestID, macID: phone.macID, phoneID: phone.id))
  phone.key = key
  return phone
 }

 private func authenticate(_ phone: TestPhone) async -> (FakeConn, UUID) {
  let (conn, id) = open()
  await service.receive(phone.hello(), on: id)
  await service.receive(phone.authMessage(from: conn.last), on: id)
  return (conn, id)
 }

 func testRejectsOldRuntimeAndWrongProtocolBeforeAnyStateChange() async {
  for revision in [415, 0] {
   let (conn, id) = open()
   await service.receive(TestPhone().hello(runtimeRevision: revision), on: id)
   XCTAssertEqual(conn.last["error"] as? String, "PROTOCOL_MISMATCH")
   XCTAssertTrue(conn.closed)
  }
  let (conn, id) = open()
  var hello = TestPhone().hello(); hello["protocol"] = 3
  await service.receive(hello, on: id)
  XCTAssertEqual(conn.last["error"] as? String, "PROTOCOL_MISMATCH")
 }

 func testRejectsWrongMacIdentityHint() async {
  let (conn, id) = open()
  await service.receive(TestPhone().hello(expectMac: String(repeating: "a", count: 32)), on: id)
  XCTAssertEqual(conn.last["error"] as? String, "MAC_ID_MISMATCH")
  XCTAssertTrue(conn.closed)
 }

 func testStrangerCannotAuthenticateOrPrepare() async {
  let stranger = TestPhone(key: Data(repeating: 7, count: 32))
  let (conn, id) = open()
  await service.receive(stranger.hello(), on: id)
  XCTAssertEqual(conn.last["trusted"] as? Bool, false)
  await service.receive(stranger.authMessage(from: conn.last), on: id)
  XCTAssertEqual(conn.last["error"] as? String, "NOT_TRUSTED")
  XCTAssertTrue(host.prepared.isEmpty)
  // prepare without authentication is not even parsed
  let (c2, id2) = open()
  await service.receive(stranger.hello(), on: id2)
  await service.receive(["cmd": "prepare", "seq": 1, "mac": "00", "sampleRate": 48000, "channels": 1, "format": "i16", "source": "microphone", "userInitiated": false], on: id2)
  XCTAssertEqual(c2.last["error"] as? String, "UNEXPECTED_COMMAND")
  XCTAssertTrue(host.prepared.isEmpty)
 }

 func testPairingRequiresUserApprovalAndStoresKeyOnlyAfterApproval() async throws {
  let phone = TestPhone()
  let (conn, id) = open()
  await service.receive(phone.hello(), on: id)
  phone.sn = conn.last["nonce"] as! String
  let keys = WifiCrypto.PairingKeys()
  await service.receive(["cmd": "pair", "pub": keys.publicBase64], on: id)
  XCTAssertEqual(conn.last["status"] as? String, "pending")
  XCTAssertNotNil(service.pendingPrompt)
  XCTAssertNil(trust.phone(id: phone.id), "nothing is trusted merely because the phone asked")
  await service.receive(["cmd": "pairStatus"], on: id)
  XCTAssertEqual(conn.last["status"] as? String, "pending")
  XCTAssertNil(conn.last["proof"])
  service.rejectPair(requestID: service.pendingPrompt!.requestID)
  XCTAssertNil(service.pendingPrompt)
  await service.receive(["cmd": "pairStatus"], on: id)
  XCTAssertEqual(conn.last["status"] as? String, "rejected")
  XCTAssertNil(conn.last["proof"])
  XCTAssertNil(trust.phone(id: phone.id))
 }

 func testPairingExpiresAndCannotBeApprovedLate() async {
  let phone = TestPhone()
  let (conn, id) = open()
  await service.receive(phone.hello(), on: id)
  await service.receive(["cmd": "pair", "pub": WifiCrypto.PairingKeys().publicBase64], on: id)
  let requestID = service.pendingPrompt!.requestID
  now = now.addingTimeInterval(WifiControlService.pairingLifetime + 1)
  XCTAssertFalse(service.approvePair(requestID: requestID))
  await service.receive(["cmd": "pairStatus"], on: id)
  XCTAssertEqual(conn.last["status"] as? String, "expired")
  XCTAssertNil(trust.phone(id: phone.id))
 }

 func testPairingRejectsMalformedKeyAndOnlyOnePromptAtATime() async {
  let (c1, i1) = open()
  await service.receive(TestPhone().hello(), on: i1)
  await service.receive(["cmd": "pair", "pub": Data(repeating: 1, count: 65).base64EncodedString()], on: i1)
  XCTAssertEqual(c1.last["error"] as? String, "BAD_REQUEST")
  let first = TestPhone(), second = TestPhone()
  let (a, ia) = open(); let (b, ib) = open()
  await service.receive(first.hello(), on: ia)
  await service.receive(["cmd": "pair", "pub": WifiCrypto.PairingKeys().publicBase64], on: ia)
  XCTAssertEqual(a.last["status"] as? String, "pending")
  await service.receive(second.hello(), on: ib)
  await service.receive(["cmd": "pair", "pub": WifiCrypto.PairingKeys().publicBase64], on: ib)
  XCTAssertEqual(b.last["error"] as? String, "PAIRING_BUSY")
  XCTAssertEqual(service.pendingPrompt?.phoneShortID, String(first.id.prefix(8)))
  // closing the connection withdraws the prompt
  service.connectionClosed(ia)
  XCTAssertNil(service.pendingPrompt)
 }

 func testPairingFloodIsRateLimited() async {
  var last: [String: Any] = [:]
  for _ in 0..<7 {
   let (conn, id) = open()
   await service.receive(TestPhone().hello(), on: id)
   await service.receive(["cmd": "pair", "pub": WifiCrypto.PairingKeys().publicBase64], on: id)
   last = conn.last
   service.connectionClosed(id)
  }
  XCTAssertEqual(last["error"] as? String, "RATE_LIMITED")
 }

 func testPhoneNameIsSanitizedAndDuplicateNamesStayDistinguishableByID() async throws {
  let a = TestPhone(name: "Pixel\u{0007}\n同名"), b = TestPhone(name: "Pixel\u{0007}\n同名")
  XCTAssertNotEqual(a.id, b.id)
  let (_, ia) = open()
  await service.receive(a.hello(), on: ia)
  await service.receive(["cmd": "pair", "pub": WifiCrypto.PairingKeys().publicBase64], on: ia)
  let prompt = try XCTUnwrap(service.pendingPrompt)
  XCTAssertEqual(prompt.phoneName, "Pixel同名")
  XCTAssertEqual(prompt.phoneShortID, String(a.id.prefix(8)))
  XCTAssertEqual(WifiControlService.sanitize("   ", limit: 10, fallback: "手机"), "手机")
  XCTAssertEqual(WifiControlService.sanitize(String(repeating: "x", count: 100), limit: 40, fallback: "m").count, 40)
 }

 func testTrustedPhoneAuthenticatesMutuallyThenPreparesWithDerivedTokenAndSignedReplies() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  XCTAssertTrue(phone.serverProofValid(conn.last), "phone must be able to verify the Mac")
  await service.receive(phone.prepare(), on: id)
  let request = try XCTUnwrap(host.prepared.first)
  XCTAssertEqual(request.phoneID, phone.id)
  XCTAssertEqual(request.audio.sampleRate, 48000)
  XCTAssertEqual(request.audioToken, WifiCrypto.audioToken(key: phone.key!, sessionID: request.sessionID, clientNonce: phone.cn, serverNonce: phone.sn))
  XCTAssertEqual(conn.last["cmd"] as? String, "prepared")
  XCTAssertEqual(conn.last["session"] as? String, request.sessionID)
  XCTAssertNil(conn.last["token"], "the audio token is never sent in the clear")
  XCTAssertTrue(phone.serverMessageValid(conn.last, fields: "\(request.sessionID)|48124|44100|1|i16|microphone"))
 }

 func testWrongProofIsRejectedAndRepeatedFailuresAreThrottled() async throws {
  let phone = try await pairedPhone()
  var lastError = ""
  for _ in 0..<6 {
   let (conn, id) = open()
   await service.receive(phone.hello(), on: id)
   var auth = phone.authMessage(from: conn.last)
   auth["proof"] = String(repeating: "0", count: 64)
   await service.receive(auth, on: id)
   lastError = conn.last["error"] as! String
   XCTAssertTrue(conn.closed)
  }
  XCTAssertEqual(lastError, "RATE_LIMITED")
  // even the correct proof is refused during the penalty window
  let (conn, id) = open()
  await service.receive(phone.hello(), on: id)
  await service.receive(phone.authMessage(from: conn.last), on: id)
  XCTAssertEqual(conn.last["error"] as? String, "RATE_LIMITED")
  now = now.addingTimeInterval(61)
  await service.tick()
  let (ok, okID) = await authenticate(phone)
  _ = okID
  XCTAssertEqual(ok.last["ok"] as? Bool, true)
 }

 func testRecordedAuthenticationCannotBeReplayedOnANewConnection() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = open()
  let hello = phone.hello()
  await service.receive(hello, on: id)
  let recorded = phone.authMessage(from: conn.last)
  await service.receive(recorded, on: id)
  XCTAssertEqual(conn.last["ok"] as? Bool, true)
  // attacker opens a new connection and replays the recorded hello + proof
  let (attacker, aid) = open()
  await service.receive(hello, on: aid)
  XCTAssertNotEqual(attacker.last["nonce"] as? String, conn.sent.first?["nonce"] as? String, "server nonce is fresh per connection")
  await service.receive(recorded, on: aid)
  XCTAssertEqual(attacker.last["error"] as? String, "AUTH_FAILED")
  XCTAssertTrue(host.prepared.isEmpty)
 }

 func testReplayedOrTamperedSessionMessagesAreRejected() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  let prepare = phone.prepare()
  await service.receive(prepare, on: id)
  XCTAssertEqual(host.prepared.count, 1)
  await service.receive(prepare, on: id)
  XCTAssertEqual(conn.last["error"] as? String, "BAD_SEQUENCE")
  XCTAssertEqual(host.prepared.count, 1)
  XCTAssertTrue(conn.closed)

  let (c2, id2) = await authenticate(phone)
  var forged = phone.prepare(rate: 16000)
  forged["sampleRate"] = 96000   // changed after signing
  await service.receive(forged, on: id2)
  XCTAssertEqual(c2.last["error"] as? String, "BAD_MAC")
  XCTAssertEqual(host.prepared.count, 1)
 }

 func testUnsupportedAudioIsRejectedWithSignedError() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.signed("prepare", fields: "12345|1|i16|microphone|0", body: ["sampleRate": 12345, "channels": 1, "format": "i16", "source": "microphone", "userInitiated": false]), on: id)
  XCTAssertEqual(conn.last["code"] as? String, "UNSUPPORTED_AUDIO")
  XCTAssertTrue(phone.serverMessageValid(conn.last, fields: "UNSUPPORTED_AUDIO"))
  XCTAssertTrue(host.prepared.isEmpty)
 }

 func testStaleStopFromReplacedSessionDoesNotEndTheNewOne() async throws {
  let phone = try await pairedPhone()
  let oldPhone = phone.clone(), newPhone = phone.clone()
  let (c1, i1) = await authenticate(oldPhone)
  await service.receive(oldPhone.prepare(), on: i1)
  let first = c1.last["session"] as! String
  // IP change: the phone reconnects on a new connection and prepares again.
  let (c2, i2) = await authenticate(newPhone)
  await service.receive(newPhone.prepare(), on: i2)
  let second = c2.last["session"] as! String
  XCTAssertNotEqual(first, second)
  XCTAssertEqual(host.ended.map(\.0), [first])
  XCTAssertEqual(host.ended.first?.1, "replaced")
  XCTAssertEqual(service.activeSessionID(), second)
  // the old (still open) connection sends its stop for the replaced session late
  await service.receive(oldPhone.stop(first), on: i1)
  XCTAssertEqual(c1.last["cmd"] as? String, "stopped")
  XCTAssertEqual(c1.last["session"] as? String, first)
  XCTAssertEqual(service.activeSessionID(), second, "stopping a replaced session cannot cancel the newer one")
  XCTAssertFalse(host.ended.map(\.0).contains(second), "late stop for replaced session must never end the newer session")
 }

 func testStopOfCurrentSessionEndsOnlyThatSession() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  let session = conn.last["session"] as! String
  await service.receive(phone.stop(session), on: id)
  XCTAssertEqual(conn.last["cmd"] as? String, "stopped")
  XCTAssertEqual(host.ended.map(\.0), [session])
  XCTAssertNil(service.activeSessionID())
  // a second stop is idempotent and replies stopped without harming any active state
  await service.receive(phone.stop(session), on: id)
  XCTAssertEqual(conn.last["cmd"] as? String, "stopped")
  XCTAssertEqual(conn.last["session"] as? String, session)
  XCTAssertNil(service.activeSessionID())
 }

 func testStopFromDifferentPhoneIsForbiddenAndPreservesActiveSession() async throws {
  let owner = try await pairedPhone(name: "持有者手机")
  let intruder = try await pairedPhone(name: "其他手机")
  let (ownerConn, ownerID) = await authenticate(owner)
  let (intruderConn, intruderID) = await authenticate(intruder)
  await service.receive(owner.prepare(), on: ownerID)
  let activeSession = try XCTUnwrap(ownerConn.last["session"] as? String)

  await service.receive(intruder.stop(activeSession), on: intruderID)
  XCTAssertEqual(intruderConn.last["cmd"] as? String, "error")
  XCTAssertEqual(intruderConn.last["code"] as? String, "FORBIDDEN")
  XCTAssertEqual(service.activeSessionID(), activeSession)
  XCTAssertTrue(host.ended.isEmpty)
 }

 func testSecondPhoneIsBusyWhileAnotherStreams() async throws {
  let first = try await pairedPhone(name: "手机甲")
  let second = try await pairedPhone(name: "手机乙")
  let (c1, i1) = await authenticate(first)
  await service.receive(first.prepare(), on: i1)
  let (c2, i2) = await authenticate(second)
  await service.receive(second.prepare(), on: i2)
  XCTAssertEqual(c2.last["code"] as? String, "BUSY")
  XCTAssertEqual(service.activeSessionID(), c1.last["session"] as? String)
  XCTAssertEqual(host.prepared.count, 1)
 }

 func testPrepareSupersededWhileReceiverStartingNeverReportsReady() async throws {
  let phone = try await pairedPhone()
  let slowPhone = phone.clone(), fastPhone = phone.clone()
  let (c1, i1) = await authenticate(slowPhone)
  host.holdNextPrepare = true
  let slowMessage = slowPhone.prepare()
  let slow = Task { @MainActor in await self.service.receive(slowMessage, on: i1) }
  while host.gate == nil { await Task.yield() }
  let first = host.prepared[0].sessionID
  let (c2, i2) = await authenticate(fastPhone)
  await service.receive(fastPhone.prepare(), on: i2)
  let second = c2.last["session"] as! String
  host.gate?.resume(); host.gate = nil
  await slow.value
  XCTAssertEqual(c1.last["code"] as? String, "SUPERSEDED")
  XCTAssertNotEqual(first, second)
  XCTAssertEqual(service.activeSessionID(), second)
  XCTAssertTrue(host.ended.contains { $0.0 == first })
  XCTAssertFalse(host.ended.contains { $0.0 == second })
 }

 func testMacUserStopPausesAutomaticSessionsUntilExplicitStart() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  let session = conn.last["session"] as! String
  XCTAssertTrue(phone.serverMessageValid(conn.last, fields: "\(session)|48124|44100|1|i16|microphone"))
  await service.endActiveSession(reason: "macUser")
  service.pausedByUser = true
  XCTAssertEqual(conn.last["cmd"] as? String, "event-stop")
  XCTAssertTrue(phone.serverMessageValid(conn.last, fields: "\(session)|macUser"))
  XCTAssertEqual(host.ended.last?.1, "macUser")
  // automatic retry (discovery, IP change, onResume) is refused
  let (c2, i2) = await authenticate(phone)
  await service.receive(phone.prepare(userInitiated: false), on: i2)
  XCTAssertEqual(c2.last["code"] as? String, "PAUSED_BY_USER")
  XCTAssertEqual(host.prepared.count, 1)
  // an explicit start on the phone resumes
  await service.receive(phone.prepare(userInitiated: true), on: i2)
  XCTAssertEqual(c2.last["cmd"] as? String, "prepared")
  XCTAssertFalse(service.pausedByUser)
 }

 func testHostSideFailureNotifiesPhoneOnceAndClearsSession() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  let session = conn.last["session"] as! String
  service.sessionEndedByHost(sessionID: "someone-else", reason: "x")
  XCTAssertEqual(service.activeSessionID(), session, "other sessions' callbacks are ignored")
  service.sessionEndedByHost(sessionID: session, reason: "audioFailed")
  XCTAssertEqual(conn.last["cmd"] as? String, "event-stop")
  XCTAssertEqual(conn.last["reason"] as? String, "audioFailed")
  let expectedMac = WifiCrypto.messageMAC(key: phone.key!, direction: "s", clientNonce: phone.cn, serverNonce: phone.sn, sequence: conn.last["seq"] as! Int, command: "event-stop", fields: "\(session)|audioFailed")
  XCTAssertEqual(conn.last["mac"] as? String, expectedMac)
  XCTAssertNil(service.activeSessionID())
  service.sessionEndedByHost(sessionID: session, reason: "macStopped")
  XCTAssertEqual(conn.sent.filter { ($0["cmd"] as? String) == "event-stop" }.count, 1)
  await service.receive(phone.status(), on: id)
  XCTAssertEqual(conn.last["state"] as? String, "ended")
 }

 func testStatusReportsStreamingOnlyWhenHostSaysSo() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  let session = conn.last["session"] as! String
  await service.receive(phone.status(), on: id)
  XCTAssertEqual(conn.last["state"] as? String, "preparing")
  host.phases[session] = .streaming
  await service.receive(phone.status(), on: id)
  XCTAssertEqual(conn.last["state"] as? String, "streaming")
  host.phases[session] = .ended
  await service.receive(phone.status(), on: id)
  XCTAssertEqual(conn.last["state"] as? String, "ended")
  XCTAssertNil(service.activeSessionID())
 }

 func testLostControlConnectionEndsOrphanedSessionAfterGrace() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  let session = conn.last["session"] as! String
  service.connectionClosed(id)
  now = now.addingTimeInterval(WifiControlService.orphanGrace - 1)
  await service.tick()
  XCTAssertEqual(service.activeSessionID(), session, "short control blips do not kill audio")
  now = now.addingTimeInterval(2)
  await service.tick()
  XCTAssertNil(service.activeSessionID())
  XCTAssertEqual(host.ended.last?.0, session)
  XCTAssertEqual(host.ended.last?.1, "control-lost")
 }

 func testSilentPhoneWithOpenConnectionIsTimedOut() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  let session = conn.last["session"] as! String
  now = now.addingTimeInterval(WifiControlService.idleTimeout + 1)
  await service.tick()
  XCTAssertTrue(conn.closed)
  XCTAssertNil(service.activeSessionID())
  XCTAssertEqual(host.ended.last?.0, session)
}

 func testForgettingPhoneRevokesTrustAndEndsItsSession() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  await service.forget(phoneID: phone.id)
  XCTAssertNil(trust.phone(id: phone.id))
  XCTAssertTrue(conn.closed)
  XCTAssertNil(service.activeSessionID())
  let (c2, i2) = open()
  await service.receive(phone.hello(), on: i2)
  await service.receive(phone.authMessage(from: c2.last), on: i2)
  XCTAssertEqual(c2.last["error"] as? String, "NOT_TRUSTED")
 }

 func testPreAuthConnectionsAreTimedOut() async {
  let (conn, _) = open()
  now = now.addingTimeInterval(WifiControlService.helloTimeout + 1)
  await service.tick()
  XCTAssertTrue(conn.closed)
 }

 func testShutdownEndsSessionAndNotifiesPhone() async throws {
  let phone = try await pairedPhone()
  let (conn, id) = await authenticate(phone)
  await service.receive(phone.prepare(), on: id)
  await service.shutdown()
  XCTAssertTrue(conn.closed)
  XCTAssertNil(service.activeSessionID())
  XCTAssertEqual(host.ended.last?.1, "macQuit")
 }
}

final class WifiTrustAndCryptoTests: XCTestCase {
 func testTrustStorePersistsIdentityAndKeysWithPrivatePermissions() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-trust-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("wifi-trust.json")
  let first = try WifiTrustStore(url: url)
  let macID = first.macID
  XCTAssertEqual(macID.count, 32)
  try first.upsert(TrustedPhone(id: "phone-12345678", name: "甲", keyHex: String(repeating: "ab", count: 32), pairedAt: 1))
  try first.upsert(TrustedPhone(id: "phone-12345678", name: "甲2", keyHex: String(repeating: "cd", count: 32), pairedAt: 2))
  let reopened = try WifiTrustStore(url: url)
  XCTAssertEqual(reopened.macID, macID, "identity is stable across launches")
  XCTAssertEqual(reopened.phones.count, 1)
  XCTAssertEqual(reopened.phone(id: "phone-12345678")?.name, "甲2")
  let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
  XCTAssertEqual(permissions, 0o600)
  try reopened.remove(id: "phone-12345678")
  XCTAssertTrue(try WifiTrustStore(url: url).phones.isEmpty)
 }

 func testCorruptTrustFileFailsClosedInsteadOfCreatingNewIdentity() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-trust-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: dir) }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent("wifi-trust.json")
  try Data("{not json".utf8).write(to: url)
  XCTAssertThrowsError(try WifiTrustStore(url: url))
 }

 func testSettingsFromBeforeWifiAutoConnectStillLoadAndDefaultOn() throws {
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as! [String: Any]
  legacy.removeValue(forKey: "wifiAutoConnect")
  let decoded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacy))
  XCTAssertTrue(decoded.wifiAutoConnect)
  var off = Settings(); off.wifiAutoConnect = false
  XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off)).wifiAutoConnect)
 }

 /// These vectors are duplicated verbatim in the Android tests; both platforms must agree.
 func testCrossPlatformVectors() {
  let key = Data((0..<32).map { UInt8($0) })
  XCTAssertEqual(WifiCrypto.hmacHex(key: key, "abc"), WifiVectors.hmacAbc)
  XCTAssertEqual(WifiCrypto.authProof(key: key, fromServer: false, macID: "mac1", phoneID: "phone1", clientNonce: "cn", serverNonce: "sn"), WifiVectors.authClient)
  XCTAssertEqual(WifiCrypto.authProof(key: key, fromServer: true, macID: "mac1", phoneID: "phone1", clientNonce: "cn", serverNonce: "sn"), WifiVectors.authServer)
  XCTAssertEqual(WifiCrypto.messageMAC(key: key, direction: "c", clientNonce: "cn", serverNonce: "sn", sequence: 3, command: "prepare", fields: "48000|1|i16|microphone|0"), WifiVectors.message)
  XCTAssertEqual(WifiCrypto.audioToken(key: key, sessionID: "sid", clientNonce: "cn", serverNonce: "sn"), WifiVectors.audioToken)
  XCTAssertEqual(WifiCrypto.verificationCode(pairingKey: key), WifiVectors.sas)
  XCTAssertEqual(WifiCrypto.pairApprovedProof(pairingKey: key, requestID: "req", macID: "mac1", phoneID: "phone1"), WifiVectors.pairApproved)
 }

 func testEqualIsExactAndLengthSafe() {
  XCTAssertTrue(WifiCrypto.equal("abcd", "abcd"))
  XCTAssertFalse(WifiCrypto.equal("abcd", "abce"))
  XCTAssertFalse(WifiCrypto.equal("abcd", "abc"))
  XCTAssertNil(WifiCrypto.bytes(fromHex: "abc"))
  XCTAssertNil(WifiCrypto.bytes(fromHex: "zz"))
  XCTAssertEqual(WifiCrypto.bytes(fromHex: "00ff"), Data([0, 255]))
 }
}

enum WifiVectors {
 static let hmacAbc = "f0133729c4163dede81e21cd47839256da58171238c8a0d874397c73b14e1e47"
 static let authClient = "0fb1371464bf3aa28008ff9965cf272585c967f1aa957854a3bf3f189493239c"
 static let authServer = "480533b34be185e0bc788e38d09f378af81fe1ea51dd9c5a49176017d8ba8ab9"
 static let message = "47b2f2299d45e9dc3f27254bed6da93483261cbbc4239f76b41831c7c46774c1"
 static let audioToken = "d39779a86a5b8f2dc1791c6e803e5817bba9b8b83d8ac276bc57ebbb0bfaff90"
 static let sas = "795361"
 static let pairApproved = "fd41055d8ac7d6f1c0c52644cf743c3f146b4076f66432c9410826fe89c09c42"
}
