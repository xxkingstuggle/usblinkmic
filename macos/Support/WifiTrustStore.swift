import Foundation

public struct TrustedPhone: Codable, Equatable, Sendable {
 public var id: String
 public var name: String
 /// 32-byte pairing key, hex. Never logged or put in a Bonjour TXT record.
 public var keyHex: String
 public var pairedAt: Int64
 public init(id: String, name: String, keyHex: String, pairedAt: Int64) {
  self.id = id; self.name = name; self.keyHex = keyHex; self.pairedAt = pairedAt
 }
}

private struct WifiTrustFile: Codable {
 var schemaVersion = 1
 var macID: String
 var phones: [TrustedPhone]
}

/// Persists this Mac's stable identity and the phones the user approved. The file lives in the
/// app's private state directory with 0600 permissions; deleting it revokes all trust.
public final class WifiTrustStore: @unchecked Sendable {
 private let url: URL
 private let lock = NSLock()
 private var file: WifiTrustFile

 public init(url: URL) throws {
  self.url = url
  if FileManager.default.fileExists(atPath: url.path) {
   let loaded = try JSONDecoder().decode(WifiTrustFile.self, from: Data(contentsOf: url))
   guard loaded.schemaVersion == 1, !loaded.macID.isEmpty else {
    throw CocoaError(.fileReadCorruptFile)
   }
   file = loaded
  } else {
   file = WifiTrustFile(macID: WifiCrypto.randomHex(byteCount: 16), phones: [])
   try persist()
  }
 }

 public var macID: String { lock.lock(); defer { lock.unlock() }; return file.macID }
 public var phones: [TrustedPhone] { lock.lock(); defer { lock.unlock() }; return file.phones }
 public func phone(id: String) -> TrustedPhone? { phones.first { $0.id == id } }

 public func upsert(_ phone: TrustedPhone) throws {
  lock.lock(); defer { lock.unlock() }
  var next = file
  next.phones.removeAll { $0.id == phone.id }
  next.phones.append(phone)
  try write(next)
  file = next
 }

 public func remove(id: String) throws {
  lock.lock(); defer { lock.unlock() }
  var next = file
  next.phones.removeAll { $0.id == id }
  try write(next)
  file = next
 }

 private func persist() throws { lock.lock(); defer { lock.unlock() }; try write(file) }

 private func write(_ value: WifiTrustFile) throws {
  let directory = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  try JSONEncoder().encode(value).write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
 }
}
