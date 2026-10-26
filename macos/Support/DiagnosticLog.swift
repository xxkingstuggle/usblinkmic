import Contracts
import Foundation

/// Bounded, local-only event metadata; never writes PCM or raw credentials.
public final class DiagnosticLog {
 private let queue = DispatchQueue(label:"usblinkmic.diagnostics", qos:.utility)
 private let pendingLock=NSLock()
 private var pendingWrites=0
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
 public func append(_ entry: LogEntry) throws {try queue.sync {try appendUnlocked(entry)}}
 public func appendAsync(_ entry: LogEntry, completion: @escaping (Error?) -> Void) {
  pendingLock.lock()
  guard pendingWrites<128 else {
   pendingLock.unlock()
   completion(NSError(domain:"USBLinkMic.Diagnostics",code:1,userInfo:[NSLocalizedDescriptionKey:"日志队列已满；本条未写入磁盘"]))
   return
  }
  pendingWrites+=1;pendingLock.unlock()
  queue.async {
   defer {self.pendingLock.lock();self.pendingWrites-=1;self.pendingLock.unlock()}
   do {try self.appendUnlocked(entry);completion(nil)} catch {completion(error)}
  }
 }
 private func appendUnlocked(_ entry: LogEntry) throws {
  let stored=Stored(date:entry.date,module:LogRedactor.redact(entry.module),stage:LogRedactor.redact(entry.stage),message:LogRedactor.redact(entry.message))
  let line=String(decoding:try JSONEncoder().encode(stored),as:UTF8.self)
  var entries=try lines();entries.append(line)
  var bytes=entries.reduce(0){$0+$1.utf8.count+1}
  while bytes>maximumBytes,!entries.isEmpty {bytes-=entries.removeFirst().utf8.count+1}
  try write(entries.joined(separator:"\n")+(entries.isEmpty ? "":"\n"))
 }
 public func load() throws -> [LogEntry] {try queue.sync {try loadUnlocked()}}
 private func loadUnlocked() throws -> [LogEntry] {
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
 public func flush() {queue.sync {}}
 public func clear() throws {try queue.sync {try write("")}}
}
