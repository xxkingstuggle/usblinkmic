import Contracts
import Foundation

/// Bounded, local-only event metadata; never writes PCM or raw credentials.
public final class DiagnosticLog {
 private let url: URL
 private let maximumBytes: Int
 public init(url: URL, maximumBytes: Int = 262144) { self.url=url;self.maximumBytes=maximumBytes }
 public func append(_ entry: LogEntry) throws {
  let directory=url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
  let line=LogRedactor.redact("\(entry.date.ISO8601Format()) \(entry.module) \(entry.stage) \(entry.message)")
  // Preserve complete recent lines, with a fixed disk bound.
  var lines=((try? String(contentsOf:url,encoding:.utf8)) ?? "").split(separator:"\n").map(String.init)
  lines.append(line)
  var bytes=lines.reduce(0){$0+$1.utf8.count+1}
  while bytes>maximumBytes,!lines.isEmpty {bytes-=lines.removeFirst().utf8.count+1}
  try (lines.joined(separator:"\n")+(lines.isEmpty ? "":"\n")).write(to:url,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
 }
}
