import Contracts
import Foundation

public struct WifiPrepareRequest: Sendable, Equatable {
 public var phoneID: String
 public var phoneName: String
 public var audio: AudioParameters
 public var sessionID: String
 /// Derived per session from the pairing key; the receiver requires an exact match.
 public var audioToken: String
 public var userInitiated: Bool

 public init(phoneID: String, phoneName: String, audio: AudioParameters, sessionID: String, audioToken: String, userInitiated: Bool) {
  self.phoneID = phoneID
  self.phoneName = phoneName
  self.audio = audio
  self.sessionID = sessionID
  self.audioToken = audioToken
  self.userInitiated = userInitiated
 }
}

public enum WifiPrepareResult: Sendable, Equatable {
 case ready(audioPort: Int, audio: AudioParameters)
 case rejected(code: String)
}

public enum WifiSessionPhase: String, Sendable { case preparing, streaming, ended }

/// The Mac-side capabilities the control protocol needs. Implemented by `SessionController`.
@MainActor public protocol WifiSessionHost: AnyObject {
 /// Starts the audio receiver for exactly this session and returns only once it is listening.
 func wifiPrepare(_ request: WifiPrepareRequest) async -> WifiPrepareResult
 /// Stops the receiver iff it still belongs to `sessionID`; later sessions are never affected.
 func wifiEnd(sessionID: String, phoneID: String?, reason: String) async
 func wifiPhase(sessionID: String) -> WifiSessionPhase
 /// Pairing prompt, trusted set or connected phone changed.
 func wifiServiceChanged()
}

extension WifiSessionHost {
 public func wifiEnd(sessionID: String, phoneID: String?, reason: String) async {
  await wifiEnd(sessionID: sessionID, reason: reason)
 }
 public func wifiEnd(sessionID: String, reason: String) async {
  await wifiEnd(sessionID: sessionID, phoneID: nil, reason: reason)
 }
}

public protocol WifiPeerConnection: AnyObject {
 func send(_ object: [String: Any])
 func close()
}

/// Authenticated control channel for automatic Wi-Fi connection. All state is main-actor
/// confined; networking lives in `WifiControlListener` (Core) and only calls `receive`.
@MainActor public final class WifiControlService {
 public static let pairingLifetime: TimeInterval = 120
 public static let helloTimeout: TimeInterval = 10
 public static let preAuthLifetime: TimeInterval = 150
 public static let idleTimeout: TimeInterval = 20
 public static let orphanGrace: TimeInterval = 15

 private enum Phase { case new, helloed, pairing, authenticated }
 private enum PairState: String { case pending, approved, rejected, expired }
 private struct Pair {
  let requestID: String
  let key: Data
  let code: String
  let expiresAt: Date
  var state: PairState = .pending
 }
 private final class Conn {
  let id = UUID()
  let handle: WifiPeerConnection
  let openedAt: Date
  var lastActivity: Date
  var phase = Phase.new
  var phoneID = "", phoneName = "", clientNonce = "", serverNonce = ""
  var key: Data?
  var nextClientSeq = 1, serverSeq = 0
  var pair: Pair?
  var sessionID: String?
  init(handle: WifiPeerConnection, now: Date) { self.handle = handle; openedAt = now; lastActivity = now }
 }
 private struct Active {
  let id: String
  let phoneID: String
  let phoneName: String
  var connectionID: UUID
  var lostAt: Date?
 }

 private let trust: WifiTrustStore
 private weak var host: WifiSessionHost?
 private let macName: String
 private let clock: () -> Date
 private var connections: [UUID: Conn] = [:]
 private var active: Active?
 private var pairAttempts: [Date] = []
 private var authFailures: [String: [Date]] = [:]

 /// Set when the user stops an automatic session on this Mac. Cleared by an explicit start,
 /// including a phone-initiated one, but never by discovery or a reconnect.
 public var pausedByUser = false { didSet { if oldValue != pausedByUser { host?.wifiServiceChanged() } } }
 public private(set) var pendingPrompt: WifiPairPrompt?
 private var pendingConnection: UUID?

 public var connectedPhoneName: String? { active?.phoneName ?? connections.values.first(where: { $0.phase == .authenticated })?.phoneName }
 public var hasActiveSession: Bool { active != nil }
 public var hasAuthenticatedConnection: Bool { connections.values.contains(where: { $0.phase == .authenticated }) }
 public func activePhoneID() -> String? { active?.phoneID }
 public func authenticatedPhoneID() -> String? { active?.phoneID ?? connections.values.first(where: { $0.phase == .authenticated })?.phoneID }
 public func activeSessionID() -> String? { active?.id }

 public init(trust: WifiTrustStore, host: WifiSessionHost, macName: String, clock: @escaping () -> Date = Date.init) {
  self.trust = trust; self.host = host; self.macName = Self.sanitize(macName, limit: 40, fallback: "Mac"); self.clock = clock
 }

 public static func sanitize(_ text: String, limit: Int, fallback: String) -> String {
  let cleaned = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
  return cleaned.isEmpty ? fallback : String(cleaned.prefix(limit))
 }

 private static func validIdentifier(_ text: String, min: Int = 8, max: Int = 64) -> Bool {
  (min...max).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
 }

 // MARK: connection lifecycle

 public func connectionOpened(_ handle: WifiPeerConnection) -> UUID {
  let conn = Conn(handle: handle, now: clock())
  connections[conn.id] = conn
  return conn.id
 }

 public func connectionClosed(_ id: UUID) {
  guard let conn = connections.removeValue(forKey: id) else { return }
  if pendingConnection == id { clearPrompt() }
  if active?.connectionID == id { active?.lostAt = clock() }
  _ = conn
 }

 public func tick() async {
  let now = clock()
  for conn in Array(connections.values) {
   let age = now.timeIntervalSince(conn.openedAt)
   let idle = now.timeIntervalSince(conn.lastActivity)
   switch conn.phase {
   case .new where age > Self.helloTimeout: conn.handle.close()
   case .helloed where age > Self.preAuthLifetime: conn.handle.close()
   case .pairing where age > Self.preAuthLifetime + Self.pairingLifetime: conn.handle.close()
   case .authenticated where idle > Self.idleTimeout: conn.handle.close()
   default: break
   }
   if conn.phase == .pairing, var pair = conn.pair, pair.state == .pending, now >= pair.expiresAt {
    pair.state = .expired; conn.pair = pair
    if pendingConnection == conn.id { clearPrompt() }
   }
  }
  if let current = active {
   let connection = connections[current.connectionID]
   let silent = connection.map { now.timeIntervalSince($0.lastActivity) > Self.idleTimeout } ?? true
   let orphaned = connection == nil
    ? now.timeIntervalSince(current.lostAt ?? now) > Self.orphanGrace
    : silent
    if orphaned {
     active = nil
     await host?.wifiEnd(sessionID: current.id, phoneID: current.phoneID, reason: "control-lost")
     host?.wifiServiceChanged()
    }
  }
  authFailures = authFailures.mapValues { $0.filter { now.timeIntervalSince($0) < 60 } }.filter { !$0.value.isEmpty }
 }

 // MARK: user decisions

 @discardableResult
 public func approvePair(requestID: String) -> Bool {
  guard pendingPrompt?.requestID == requestID, let id = pendingConnection, let conn = connections[id],
        var pair = conn.pair, pair.requestID == requestID, pair.state == .pending, clock() < pair.expiresAt else { return false }
  do {
   try trust.upsert(TrustedPhone(id: conn.phoneID, name: conn.phoneName, keyHex: WifiCrypto.hex(pair.key), pairedAt: Int64(clock().timeIntervalSince1970)))
  } catch {
   pair.state = .rejected; conn.pair = pair; clearPrompt()
   return false
  }
  pair.state = .approved; conn.pair = pair
  clearPrompt()
  return true
 }

 public func rejectPair(requestID: String) {
  guard pendingPrompt?.requestID == requestID, let id = pendingConnection, let conn = connections[id], var pair = conn.pair, pair.requestID == requestID else { return }
  pair.state = .rejected; conn.pair = pair
  clearPrompt()
 }

 public func forget(phoneID: String) async {
  try? trust.remove(id: phoneID)
  for conn in connections.values where conn.phoneID == phoneID { conn.handle.close() }
  if active?.phoneID == phoneID { await endActiveSession(reason: "forgotten") }
  host?.wifiServiceChanged()
 }

 /// Mac-side explicit start. Requests the connected phone to initiate an audio session via prepare.
 @discardableResult
 public func requestStart() -> Bool {
  guard let conn = (active.flatMap { a in connections[a.connectionID] }) ?? connections.values.first(where: { $0.phase == .authenticated }) else { return false }
  pausedByUser = false
  push(conn, command: "event-start", ack: 0, fields: [:], macFields: "")
  return true
 }

 /// Mac-side stop (user, quit or settings change). Notifies the phone on its control channel.
 public func endActiveSession(reason: String) async {
  guard let current = active else { return }
  active = nil
  if let conn = connections[current.connectionID], conn.phase == .authenticated {
   push(conn, command: "event-stop", ack: 0, fields: ["session": current.id, "reason": reason], macFields: "\(current.id)|\(reason)")
  }
  await host?.wifiEnd(sessionID: current.id, phoneID: current.phoneID, reason: reason)
  host?.wifiServiceChanged()
 }

 /// Receiver already stopped by the host (audio failure). Tell the phone, do not touch the host again.
 public func sessionEndedByHost(sessionID: String, reason: String) {
  guard let current = active, current.id == sessionID else { return }
  active = nil
  if let conn = connections[current.connectionID], conn.phase == .authenticated {
   push(conn, command: "event-stop", ack: 0, fields: ["session": current.id, "reason": reason], macFields: "\(current.id)|\(reason)")
  }
  host?.wifiServiceChanged()
 }

 public func shutdown() async {
  await endActiveSession(reason: "macQuit")
  clearPrompt()
  for conn in Array(connections.values) { conn.handle.close() }
  connections.removeAll()
 }

 private func clearPrompt() {
  pendingPrompt = nil; pendingConnection = nil
  host?.wifiServiceChanged()
 }

 // MARK: protocol

 public func receive(_ message: [String: Any], on id: UUID) async {
  guard let conn = connections[id] else { return }
  let command = message["cmd"] as? String ?? ""
  switch (conn.phase, command) {
  case (.new, "hello"): hello(message, conn)
  case (.helloed, "auth"): auth(message, conn)
  case (.helloed, "pair"): pair(message, conn)
  case (.pairing, "pairStatus"): pairStatus(conn)
  case (.authenticated, _): await authenticated(message, command, conn)
  default: fail(conn, "UNEXPECTED_COMMAND")
  }
 }

 private func preError(_ conn: Conn, _ code: String, close: Bool = true) {
  conn.handle.send(["ok": false, "error": code])
  if close { conn.handle.close() }
 }
 private func fail(_ conn: Conn, _ code: String) { preError(conn, code) }

 private func hello(_ m: [String: Any], _ conn: Conn) {
  guard m["protocol"] as? Int == Capabilities.protocolVersion, m["wifi"] as? Int == Capabilities.wifiRevision,
        let revision = m["runtimeRevision"] as? Int, revision >= Capabilities.runtimeRevision else {
   return preError(conn, "PROTOCOL_MISMATCH")
  }
  guard let phoneID = m["phoneID"] as? String, Self.validIdentifier(phoneID),
        let nonce = m["nonce"] as? String, Self.validIdentifier(nonce, min: 16, max: 64) else {
   return preError(conn, "BAD_REQUEST")
  }
  if let expected = m["macID"] as? String, !expected.isEmpty, expected != trust.macID {
   return preError(conn, "MAC_ID_MISMATCH")
  }
  conn.phoneID = phoneID
  conn.phoneName = Self.sanitize(m["phoneName"] as? String ?? "", limit: 40, fallback: "Android 手机")
  conn.clientNonce = nonce
  conn.serverNonce = WifiCrypto.randomHex(byteCount: 16)
  conn.phase = .helloed
  conn.lastActivity = clock()
  conn.handle.send([
   "ok": true, "cmd": "hello", "protocol": Capabilities.protocolVersion, "wifi": Capabilities.wifiRevision,
   "runtimeRevision": Capabilities.runtimeRevision, "macID": trust.macID, "macName": macName,
   "nonce": conn.serverNonce, "trusted": trust.phone(id: phoneID) != nil
  ])
 }

 private func auth(_ m: [String: Any], _ conn: Conn) {
  let now = clock()
  guard (authFailures[conn.phoneID] ?? []).filter({ now.timeIntervalSince($0) < 60 }).count < 5 else {
   return preError(conn, "RATE_LIMITED")
  }
  guard let phone = trust.phone(id: conn.phoneID), let key = WifiCrypto.bytes(fromHex: phone.keyHex) else {
   return preError(conn, "NOT_TRUSTED")
  }
  let expected = WifiCrypto.authProof(key: key, fromServer: false, macID: trust.macID, phoneID: conn.phoneID, clientNonce: conn.clientNonce, serverNonce: conn.serverNonce)
  guard let proof = m["proof"] as? String, WifiCrypto.equal(proof, expected) else {
   authFailures[conn.phoneID, default: []].append(now)
   return preError(conn, "AUTH_FAILED")
  }
  conn.key = key
  conn.phase = .authenticated
  conn.lastActivity = now
  conn.handle.send([
   "ok": true, "cmd": "auth",
   "proof": WifiCrypto.authProof(key: key, fromServer: true, macID: trust.macID, phoneID: conn.phoneID, clientNonce: conn.clientNonce, serverNonce: conn.serverNonce)
  ])
 }

 private func pair(_ m: [String: Any], _ conn: Conn) {
  let now = clock()
  pairAttempts = pairAttempts.filter { now.timeIntervalSince($0) < 60 }
  guard pairAttempts.count < 5 else { return preError(conn, "RATE_LIMITED") }
  guard let phonePub = m["pub"] as? String else { return preError(conn, "BAD_REQUEST") }
  if let other = pendingConnection, other != conn.id, let existing = connections[other] {
   guard existing.phoneID == conn.phoneID else { return preError(conn, "PAIRING_BUSY") }
   existing.handle.close()
   clearPrompt()
  }
  pairAttempts.append(now)
  let keys = WifiCrypto.PairingKeys()
  guard let key = WifiCrypto.pairingKey(
   privateKey: keys.privateKey, peerPublicBase64: phonePub, macID: trust.macID, phoneID: conn.phoneID,
   clientNonce: conn.clientNonce, serverNonce: conn.serverNonce, phonePublicBase64: phonePub, macPublicBase64: keys.publicBase64
  ) else { return preError(conn, "BAD_REQUEST") }
  let requestID = WifiCrypto.randomHex(byteCount: 8)
  let expires = now.addingTimeInterval(Self.pairingLifetime)
  let code = WifiCrypto.verificationCode(pairingKey: key)
  conn.pair = Pair(requestID: requestID, key: key, code: code, expiresAt: expires)
  conn.phase = .pairing
  conn.lastActivity = now
  pendingConnection = conn.id
  pendingPrompt = WifiPairPrompt(requestID: requestID, phoneName: conn.phoneName, phoneShortID: String(conn.phoneID.prefix(8)), code: code, expiresAt: expires)
  host?.wifiServiceChanged()
  conn.handle.send(["ok": true, "cmd": "pair", "status": PairState.pending.rawValue, "macPub": keys.publicBase64, "requestID": requestID, "expiresIn": Int(Self.pairingLifetime)])
 }

 private func pairStatus(_ conn: Conn) {
  guard var pair = conn.pair else { return preError(conn, "UNEXPECTED_COMMAND") }
  if pair.state == .pending, clock() >= pair.expiresAt { pair.state = .expired; conn.pair = pair }
  conn.lastActivity = clock()
  var reply: [String: Any] = ["ok": true, "cmd": "pairStatus", "status": pair.state.rawValue, "requestID": pair.requestID]
  if pair.state == .approved {
   reply["proof"] = WifiCrypto.pairApprovedProof(pairingKey: pair.key, requestID: pair.requestID, macID: trust.macID, phoneID: conn.phoneID)
  }
  conn.handle.send(reply)
  if pair.state != .pending { conn.handle.close() }
 }

 private func authenticated(_ m: [String: Any], _ command: String, _ conn: Conn) async {
  guard let key = conn.key, let seq = m["seq"] as? Int, seq == conn.nextClientSeq, let mac = m["mac"] as? String else {
   return preError(conn, "BAD_SEQUENCE")
  }
  let fields: String
  switch command {
  case "prepare":
   guard let rate = m["sampleRate"] as? Int, let channels = m["channels"] as? Int, let format = m["format"] as? String,
         let source = m["source"] as? String,
         let initiated = (m["userInitiated"] as? Bool) ?? ((m["userInitiated"] as? Int).map { $0 != 0 }) else { return preError(conn, "BAD_REQUEST") }
   fields = "\(rate)|\(channels)|\(format)|\(source)|\(initiated ? 1 : 0)"
  case "status": fields = ""
  case "stop":
   guard let session = m["session"] as? String, let reason = m["reason"] as? String else { return preError(conn, "BAD_REQUEST") }
   fields = "\(session)|\(reason)"
  default: return preError(conn, "UNEXPECTED_COMMAND")
  }
  let expected = WifiCrypto.messageMAC(key: key, direction: "c", clientNonce: conn.clientNonce, serverNonce: conn.serverNonce, sequence: seq, command: command, fields: fields)
  guard WifiCrypto.equal(mac, expected) else { return preError(conn, "BAD_MAC") }
  conn.nextClientSeq += 1
  conn.lastActivity = clock()
  switch command {
  case "prepare": await prepare(m, conn, seq: seq)
  case "status": status(conn, seq: seq)
  default: await stop(m, conn, seq: seq)
  }
 }

 private func prepare(_ m: [String: Any], _ conn: Conn, seq: Int) async {
  func reject(_ code: String) { push(conn, command: "error", ack: seq, fields: ["code": code], macFields: code) }
  var audio = AudioParameters()
  guard let rate = m["sampleRate"] as? Int, Capabilities.sampleRates.contains(rate),
        let channels = m["channels"] as? Int, Capabilities.channels.contains(channels),
        let format = (m["format"] as? String).flatMap(PCMFormat.init(rawValue:)),
        let source = (m["source"] as? String).flatMap(RecordingSource.init(rawValue:)) else { return reject("UNSUPPORTED_AUDIO") }
  audio.sampleRate = rate; audio.channels = channels; audio.format = format; audio.source = source
  let userInitiated = (m["userInitiated"] as? Bool) ?? ((m["userInitiated"] as? Int).map { $0 != 0 }) ?? false
  if userInitiated { pausedByUser = false }
  guard !pausedByUser else { return reject("PAUSED_BY_USER") }
  if let current = active {
   guard current.phoneID == conn.phoneID else { return reject("BUSY") }
   // Same phone: its previous session (possibly on a dead connection) is superseded.
   active = nil
   await host?.wifiEnd(sessionID: current.id, phoneID: current.phoneID, reason: "replaced")
  }
  let sessionID = WifiCrypto.randomHex(byteCount: 16)
  guard let key = conn.key else { return reject("NOT_TRUSTED") }
  let token = WifiCrypto.audioToken(key: key, sessionID: sessionID, clientNonce: conn.clientNonce, serverNonce: conn.serverNonce)
  active = Active(id: sessionID, phoneID: conn.phoneID, phoneName: conn.phoneName, connectionID: conn.id, lostAt: nil)
  conn.sessionID = sessionID
  host?.wifiServiceChanged()
  let result = await host?.wifiPrepare(WifiPrepareRequest(phoneID: conn.phoneID, phoneName: conn.phoneName, audio: audio, sessionID: sessionID, audioToken: token, userInitiated: userInitiated)) ?? .rejected(code: "UNAVAILABLE")
  // A newer prepare, a stop or a forget may have run while the receiver was starting.
  guard active?.id == sessionID else {
   await host?.wifiEnd(sessionID: sessionID, phoneID: conn.phoneID, reason: "superseded")
   return reject("SUPERSEDED")
  }
  switch result {
  case .rejected(let code):
   active = nil
   host?.wifiServiceChanged()
   reject(code)
  case .ready(let port, let effective):
   let fields = "\(sessionID)|\(port)|\(effective.sampleRate)|\(effective.channels)|\(effective.format.rawValue)|\(effective.source.rawValue)"
   push(conn, command: "prepared", ack: seq, fields: [
    "session": sessionID, "audioPort": port, "sampleRate": effective.sampleRate, "channels": effective.channels,
    "format": effective.format.rawValue, "source": effective.source.rawValue
   ], macFields: fields)
  }
 }

 private func status(_ conn: Conn, seq: Int) {
  var state = "ended"
  var session = conn.sessionID ?? ""
  if let id = conn.sessionID, active?.id == id {
   switch host?.wifiPhase(sessionID: id) ?? .ended {
   case .preparing: state = "preparing"
   case .streaming: state = "streaming"
   case .ended:
    active = nil
    host?.wifiServiceChanged()
   }
  } else if conn.sessionID == nil { session = "" }
  push(conn, command: "state", ack: seq, fields: ["session": session, "state": state], macFields: "\(session)|\(state)")
 }

 private func stop(_ m: [String: Any], _ conn: Conn, seq: Int) async {
  let session = m["session"] as? String ?? ""
  guard !session.isEmpty else {
   return push(conn, command: "error", ack: seq, fields: ["code": "BAD_REQUEST"], macFields: "BAD_REQUEST")
  }
  if let current = active, current.id == session {
   guard current.phoneID == conn.phoneID else {
    return push(conn, command: "error", ack: seq, fields: ["code": "FORBIDDEN"], macFields: "FORBIDDEN")
   }
   active = nil
   pausedByUser = true
   await host?.wifiEnd(sessionID: session, phoneID: conn.phoneID, reason: "phone-\(m["reason"] as? String ?? "stop")")
   host?.wifiServiceChanged()
  } else {
   await host?.wifiEnd(sessionID: session, phoneID: conn.phoneID, reason: "phone-\(m["reason"] as? String ?? "stop")")
  }
  push(conn, command: "stopped", ack: seq, fields: ["session": session], macFields: session)
 }

 private func push(_ conn: Conn, command: String, ack: Int, fields: [String: Any], macFields: String) {
  guard let key = conn.key else { return }
  conn.serverSeq += 1
  var body = fields
  body["ok"] = command != "error"
  body["cmd"] = command
  body["seq"] = conn.serverSeq
  body["ack"] = ack
  body["mac"] = WifiCrypto.messageMAC(key: key, direction: "s", clientNonce: conn.clientNonce, serverNonce: conn.serverNonce, sequence: conn.serverSeq, command: command, fields: macFields)
  conn.handle.send(body)
 }
}
