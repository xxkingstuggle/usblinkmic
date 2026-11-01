import Contracts
import Foundation

/// Bounded, local-only event metadata; never writes PCM or raw credentials.
public final class DiagnosticLog {
 private let queue = DispatchQueue(label: "usblinkmic.diagnostics", qos: .utility)
 private let pendingLock = NSLock()
 private var pendingWrites = 0
 private let url: URL
 private let maximumBytes: Int
 private var fileHandle: FileHandle?
 private var currentFileSize: Int = 0
 private var initialized = false

 private struct Stored: Codable {
  let date: Date
  let module: String
  let stage: String
  let message: String
 }

 public init(url: URL, maximumBytes: Int = 262144) {
  self.url = url
  self.maximumBytes = max(128, maximumBytes)
 }

 deinit {
  try? fileHandle?.close()
 }

 private func closeHandleUnlocked() {
  try? fileHandle?.close()
  fileHandle = nil
 }

 private func ensureFileUnlocked() throws {
  let fm = FileManager.default
  let directory = url.deletingLastPathComponent()
  if !fm.fileExists(atPath: directory.path) {
   try fm.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  if !fm.fileExists(atPath: url.path) {
   closeHandleUnlocked()
   _ = fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
   try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
   currentFileSize = 0
   initialized = true
  } else if !initialized {
   try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
   let attrs = try? fm.attributesOfItem(atPath: url.path)
   currentFileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
   initialized = true
  }
 }

 private func linesUnlocked() throws -> [String] {
  guard FileManager.default.fileExists(atPath: url.path) else { return [] }
  return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
 }

 private func writeFullUnlocked(_ text: String) throws {
  closeHandleUnlocked()
  let directory = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  let data = Data(text.utf8)
  try data.write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  currentFileSize = data.count
  initialized = true
 }

 public func append(_ entry: LogEntry) throws {
  try queue.sync { try appendUnlocked(entry) }
 }

 public func appendAsync(_ entry: LogEntry, completion: @escaping (Error?) -> Void) {
  pendingLock.lock()
  guard pendingWrites < 128 else {
   pendingLock.unlock()
   completion(NSError(domain: "USBLinkMic.Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "日志队列已满；本条未写入磁盘"]))
   return
  }
  pendingWrites += 1
  pendingLock.unlock()
  queue.async {
   defer {
    self.pendingLock.lock()
    self.pendingWrites -= 1
    self.pendingLock.unlock()
   }
   do {
    try self.appendUnlocked(entry)
    completion(nil)
   } catch {
    completion(error)
   }
  }
 }

 private static func isCritical(stage: String, message: String) -> Bool {
  let lowerStage = stage.lowercased()
  if lowerStage == "metrics" || lowerStage == "healthsummary" || lowerStage == "telemetry" || lowerStage == "event" {
   return false
  }
  let criticalTokens = [
   "boot", "start", "stop", "sessionend", "recover", "fail", "error", "invalid",
   "saved", "shutdown", "deadline", "handshake", "disconnect", "cleanup", "action",
   "正在停止", "资源恢复", "已停止", "失败", "未完成"
  ]
  if criticalTokens.contains(where: { lowerStage.contains($0) }) {
   return true
  }
  return message.contains("CLEANUP_INCOMPLETE") || message.contains("OUTPUT_") || message.contains("DEVICE_")
 }

 private static func isCriticalLine(_ line: String) -> Bool {
  if let stored = try? JSONDecoder().decode(Stored.self, from: Data(line.utf8)) {
   return isCritical(stage: stored.stage, message: stored.message)
  }
  return false
 }

 private func appendUnlocked(_ entry: LogEntry) throws {
  let stored = Stored(
   date: entry.date,
   module: LogRedactor.redact(entry.module),
   stage: LogRedactor.redact(entry.stage),
   message: LogRedactor.redact(entry.message)
  )
  let line = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
  let lineData = Data((line + "\n").utf8)

  try ensureFileUnlocked()

  if currentFileSize + lineData.count <= maximumBytes {
   if fileHandle == nil {
    fileHandle = try FileHandle(forWritingTo: url)
   }
   if let handle = fileHandle {
    try handle.seekToEnd()
    try handle.write(contentsOf: lineData)
    currentFileSize += lineData.count
    return
   }
  }

  closeHandleUnlocked()
  var entries = (try? linesUnlocked()) ?? []
  entries.append(line)
  let targetBudget = maximumBytes >= 4096 ? max(lineData.count, (maximumBytes * 3) / 4) : maximumBytes
  let compacted = Self.compactEntries(entries, targetBytes: min(maximumBytes, targetBudget))
  try writeFullUnlocked(compacted.joined(separator: "\n") + (compacted.isEmpty ? "" : "\n"))
 }

 private static func compactEntries(_ entries: [String], targetBytes: Int) -> [String] {
  guard !entries.isEmpty else { return [] }
  let sizes = entries.map { $0.utf8.count + 1 }
  let totalBytes = sizes.reduce(0, +)
  if totalBytes <= targetBytes {
   return entries
  }

  // Always try to keep the newest entry if it fits at all.
  guard let lastSize = sizes.last, lastSize <= targetBytes else {
   return []
  }

  // Reserve up to 35% of budget for recent critical lifecycle/error lines so high-frequency logs cannot evict them all.
  let criticalBudget = targetBytes >= 320 ? (targetBytes * 35) / 100 : 0
  let tailBudget = targetBytes - criticalBudget

  var selectedIndices = Set<Int>()
  var usedBytes = 0

  // 1. Fill from newest tail first within tailBudget (always including the last entry).
  for idx in stride(from: entries.count - 1, through: 0, by: -1) {
   let s = sizes[idx]
   if idx == entries.count - 1 || usedBytes + s <= tailBudget {
    selectedIndices.insert(idx)
    usedBytes += s
   } else {
    break
   }
  }

  // 2. Retain newest unselected critical entries within remaining budget.
  if criticalBudget > 0 {
   for idx in stride(from: entries.count - 1, through: 0, by: -1) where !selectedIndices.contains(idx) {
    let s = sizes[idx]
    guard usedBytes + s <= targetBytes else { continue }
    if isCriticalLine(entries[idx]) {
     selectedIndices.insert(idx)
     usedBytes += s
    }
   }
  }

  // 3. Backfill any remaining budget with newer unselected entries from the tail.
  for idx in stride(from: entries.count - 1, through: 0, by: -1) where !selectedIndices.contains(idx) {
   let s = sizes[idx]
   if usedBytes + s <= targetBytes {
    selectedIndices.insert(idx)
    usedBytes += s
   } else {
    break
   }
  }

  return selectedIndices.sorted().map { entries[$0] }
 }

 public func load() throws -> [LogEntry] {
  try queue.sync { try loadUnlocked() }
 }

 private func loadUnlocked() throws -> [LogEntry] {
  try linesUnlocked().map { line in
   if let stored = try? JSONDecoder().decode(Stored.self, from: Data(line.utf8)) {
    var entry = LogEntry(module: stored.module, stage: stored.stage, message: LogRedactor.redact(stored.message))
    entry.date = stored.date
    return entry
   }
   // Preserve the existing 4.0.1–4.0.3 plain-text history as well.
   let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
   if fields.count == 4, let date = ISO8601DateFormatter().date(from: fields[0]) {
    var entry = LogEntry(module: fields[1], stage: fields[2], message: LogRedactor.redact(fields[3]))
    entry.date = date
    return entry
   }
   return LogEntry(module: "logs", stage: "history", message: LogRedactor.redact(line))
  }
 }

 public func exportText() throws -> String {
  let header = "# USBLinkMic Diagnostics v=\(Capabilities.version) rev=\(Capabilities.runtimeRevision) protocol=\(Capabilities.protocolVersion)"
  let rows = try load().map { "\($0.date.ISO8601Format()) \($0.module) \($0.stage) \($0.message)" }
  return ([header] + rows).joined(separator: "\n") + "\n"
 }

 public func flush() {
  queue.sync {
   try? fileHandle?.synchronize()
  }
 }

 public func clear() throws {
  try queue.sync {
   try writeFullUnlocked("")
  }
 }
}
