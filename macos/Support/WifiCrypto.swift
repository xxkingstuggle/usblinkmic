import CryptoKit
import Foundation

/// Cryptographic helpers for the Wi-Fi control protocol (contracts/wifi-auto-connect-v1.md).
/// Every authenticated string below is byte-for-byte mirrored by the Android client.
public enum WifiCrypto {
 public static func hex(_ data: some Sequence<UInt8>) -> String {
  data.map { String(format: "%02x", $0) }.joined()
 }

 public static func bytes(fromHex text: String) -> Data? {
  guard text.count % 2 == 0, !text.isEmpty else { return nil }
  var data = Data(); data.reserveCapacity(text.count / 2)
  var index = text.startIndex
  while index < text.endIndex {
   let next = text.index(index, offsetBy: 2)
   guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
   data.append(byte); index = next
  }
  return data
 }

 public static func randomHex(byteCount: Int = 16) -> String {
  var generator = SystemRandomNumberGenerator()
  return hex((0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
 }

 public static func hmacHex(key: Data, _ message: String) -> String {
  hex(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
 }

 /// Constant-time comparison of two hex digests.
 public static func equal(_ a: String, _ b: String) -> Bool {
  let left = Array(a.utf8), right = Array(b.utf8)
  guard left.count == right.count else { return false }
  var difference: UInt8 = 0
  for index in left.indices { difference |= left[index] ^ right[index] }
  return difference == 0
 }

 // MARK: Pairing (ephemeral P-256 ECDH, compared six-digit code)

 public struct PairingKeys {
  public let privateKey: P256.KeyAgreement.PrivateKey
  public var publicBase64: String { privateKey.publicKey.x963Representation.base64EncodedString() }
  public init() { privateKey = P256.KeyAgreement.PrivateKey() }
 }

 /// Returns the 32-byte long-term pairing key shared by both devices.
 public static func pairingKey(
  privateKey: P256.KeyAgreement.PrivateKey,
  peerPublicBase64: String,
  macID: String, phoneID: String,
  clientNonce: String, serverNonce: String,
  phonePublicBase64: String, macPublicBase64: String
 ) -> Data? {
  guard let raw = Data(base64Encoded: peerPublicBase64), raw.count == 65, raw.first == 4,
        let peer = try? P256.KeyAgreement.PublicKey(x963Representation: raw),
        let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
  let transcript = "usblinkmic-wifi-pair-v1|\(macID)|\(phoneID)|\(clientNonce)|\(serverNonce)|\(phonePublicBase64)|\(macPublicBase64)"
  let code = secret.withUnsafeBytes { HMAC<SHA256>.authenticationCode(for: Data(transcript.utf8), using: SymmetricKey(data: Data($0))) }
  return Data(code)
 }

 /// Six decimal digits both users compare; derived from the shared pairing key.
 public static func verificationCode(pairingKey: Data) -> String {
  let digest = Array(HMAC<SHA256>.authenticationCode(for: Data("sas".utf8), using: SymmetricKey(data: pairingKey)))
  let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  return String(format: "%06u", value % 1_000_000)
 }

 public static func pairApprovedProof(pairingKey: Data, requestID: String, macID: String, phoneID: String) -> String {
  hmacHex(key: pairingKey, "pair-approved|\(requestID)|\(macID)|\(phoneID)")
 }

 // MARK: Session authentication

 public static func authProof(key: Data, fromServer: Bool, macID: String, phoneID: String, clientNonce: String, serverNonce: String) -> String {
  hmacHex(key: key, "\(fromServer ? "auth-s" : "auth-c")|\(macID)|\(phoneID)|\(clientNonce)|\(serverNonce)")
 }

 /// `direction` is "c" for phone→Mac and "s" for Mac→phone. `sequence` is per direction.
 public static func messageMAC(key: Data, direction: String, clientNonce: String, serverNonce: String, sequence: Int, command: String, fields: String) -> String {
  hmacHex(key: key, "msg|\(direction)|\(clientNonce)|\(serverNonce)|\(sequence)|\(command)|\(fields)")
 }

 /// Per-session audio token. Derived on both sides and never transmitted in the control channel.
 public static func audioToken(key: Data, sessionID: String, clientNonce: String, serverNonce: String) -> String {
  hmacHex(key: key, "audio|\(sessionID)|\(clientNonce)|\(serverNonce)")
 }
}
