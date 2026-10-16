import Contracts
import Foundation

/// Bounded, local-only event metadata; never writes PCM or raw credentials.
public final class DiagnosticLog {
 private let url: URL
 private let maximumBytes: Int
 private struct Stored:Codable {let date:Date;let module:String;let stage:String;let message:String}
 public init(url: URL, maximumBytes: Int = 262144) { self.url=url;self.maximumBytes=maximumBytes }
 private func lines() throws -> [String] {
  guard FileManager.default.fileExists(atPath:url.path) else{return []}
  return try String(contentsOf:url,encoding:.utf8).split(separator:"\n").map(String.init)
 }
 private func write(_ text:String) throws {
  let directory=url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
  try text.write(to:url,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
 }
 public func append(_ entry: LogEntry) throws {
  let stored=Stored(date:entry.date,module:LogRedactor.redact(entry.module),stage:LogRedactor.redact(entry.stage),message:LogRedactor.redact(entry.message))
  let line=String(decoding:try JSONEncoder().encode(stored),as:UTF8.self)
  var entries=try lines();entries.append(line)
  var bytes=entries.reduce(0){$0+$1.utf8.count+1}
  while bytes>maximumBytes,!entries.isEmpty {bytes-=entries.removeFirst().utf8.count+1}
  try write(entries.joined(separator:"\n")+(entries.isEmpty ? "":"\n"))
 }
 public func load() throws -> [LogEntry] {
  try lines().map {line in
   if let stored=try? JSONDecoder().decode(Stored.self,from:Data(line.utf8)) {
    var entry=LogEntry(module:stored.module,stage:stored.stage,message:LogRedactor.redact(stored.message));entry.date=stored.date;return entry
   }
   // Preserve the existing 4.0.1–4.0.3 plain-text history as well.
   let fields=line.split(separator:" ",maxSplits:3,omittingEmptySubsequences:false).map(String.init)
   if fields.count==4,let date=ISO8601DateFormatter().date(from:fields[0]) {
    var entry=LogEntry(module:fields[1],stage:fields[2],message:LogRedactor.redact(fields[3]));entry.date=date;return entry
   }
   return LogEntry(module:"logs",stage:"history",message:LogRedactor.redact(line))
  }
 }
 public func exportText() throws -> String {
  try load().map {"\($0.date.ISO8601Format()) \($0.module) \($0.stage) \($0.message)"}.joined(separator:"\n")+"\n"
 }
 public func clear() throws {try write("")}
}
