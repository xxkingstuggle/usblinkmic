import Foundation
import Darwin

public enum ProcessTerminationReason: String, Equatable, Sendable {
 case exit
 case uncaughtSignal
}
public struct CommandResult: Equatable, Sendable {
 public let code: Int32
 public let output: String
 public let terminationReason: ProcessTerminationReason
 public let terminationSignal: Int32?
 public init(
  code: Int32,
  output: String,
  terminationReason: ProcessTerminationReason = .exit,
  terminationSignal: Int32? = nil
 ) {
  self.code = code
  self.output = output
  self.terminationReason = terminationReason
  self.terminationSignal = terminationSignal
 }
}
public enum LinkError: LocalizedError {
 case failure(String, String)
 public var errorDescription: String? { if case let .failure(code, message) = self { return "[\(code)] \(message)" }; return nil }
}
public final class ProcessGroupCancellation: @unchecked Sendable {
 private let lock = NSLock()
 private var cancelled = false
 private var pendingSpawns = 0
 private var active: [UUID: ProcessExecution] = [:]
 public init() {}
 public var isCancelled: Bool {
  lock.lock()
  defer { lock.unlock() }
  return cancelled
 }
 internal func beginSpawn() -> Bool {
  lock.lock()
  defer { lock.unlock() }
  if cancelled { return false }
  pendingSpawns += 1
  return true
 }
 internal func completeSpawn(_ id: UUID, execution: ProcessExecution?) {
  if let execution {
   lock.lock()
   if !cancelled {
    active[id] = execution
    pendingSpawns = max(0, pendingSpawns - 1)
    lock.unlock()
   } else {
    lock.unlock()
    execution.terminateSynchronously()
    lock.lock()
    pendingSpawns = max(0, pendingSpawns - 1)
    lock.unlock()
   }
  } else {
   lock.lock()
   pendingSpawns = max(0, pendingSpawns - 1)
   lock.unlock()
  }
 }
 fileprivate func unregister(_ id: UUID) {
  lock.lock()
  active.removeValue(forKey: id)
  lock.unlock()
 }
 public func cancelAll() {
  lock.lock()
  cancelled = true
  let executions = Array(active.values)
  active.removeAll()
  lock.unlock()
  if !executions.isEmpty {
   var pending = [ProcessExecution]()
   for execution in executions {
    if !execution.beginDeadlineCancellationSynchronously() {
     pending.append(execution)
    }
   }
   if !pending.isEmpty {
    let termDeadline = ProcessInfo.processInfo.systemUptime + 0.04
    while ProcessInfo.processInfo.systemUptime < termDeadline {
     pending.removeAll { $0.pollDeadlineCompletionSynchronously() }
     if pending.isEmpty { break }
     usleep(2_000)
    }
    for execution in pending {
     execution.finishDeadlineCancellationSynchronously()
    }
   }
  }
  let spawnWaitDeadline = ProcessInfo.processInfo.systemUptime + 0.12
  while ProcessInfo.processInfo.systemUptime < spawnWaitDeadline {
   lock.lock()
   let remainingSpawns = pendingSpawns
   let lateExecutions = Array(active.values)
   active.removeAll()
   lock.unlock()
   for execution in lateExecutions {
    execution.terminateSynchronously()
   }
   if remainingSpawns == 0 { break }
   usleep(2_000)
  }
 }
}

private final class ProcessCancellation: @unchecked Sendable {
 private let lock = NSLock()
 private var terminateHandler: (() -> Void)?
 private var cancelled = false
 func register(_ handler: @escaping () -> Void) {
  lock.lock()
  terminateHandler = handler
  let shouldTerminate = cancelled
  lock.unlock()
  if shouldTerminate { handler() }
 }
 func cancel() {
  lock.lock()
  cancelled = true
  let handler = terminateHandler
  lock.unlock()
  handler?()
 }
}

internal final class ProcessExecution: @unchecked Sendable {
 static let maximumOutputBytes = 2_000_000
 static let maximumChunksPerDrainTurn = 8
 private let id = UUID()
 private let pid: pid_t
 private let readFD: Int32
 private let queue: DispatchQueue
 private weak var group: ProcessGroupCancellation?
 private let resumeLock = NSLock()
 private var continuation: CheckedContinuation<CommandResult, Error>?
 private var outputData = Data()
 private var eofReached = false
 private var processReaped = false
 private var exitCode: Int32 = 0
 private var terminationSignal: Int32? = nil
 private var interrupted = false
 private var finalKillSent = false
 private var completed = false
 private var readFDClosed = false
 private var drainContinuationScheduled = false
 private var readSource: DispatchSourceRead?
 private var procSource: DispatchSourceProcess?
 private var timeoutTimer: DispatchSourceTimer?
 private var killTimer: DispatchSourceTimer?
 private var forceTimer: DispatchSourceTimer?
 private var exitPollTimer: DispatchSourceTimer?
 private var retainedSelf: ProcessExecution?

 init(pid: pid_t, readFD: Int32, group: ProcessGroupCancellation?, continuation: CheckedContinuation<CommandResult, Error>) {
  self.pid = pid
  self.readFD = readFD
  self.group = group
  self.continuation = continuation
  self.queue = DispatchQueue(label: "usblinkmic.process.\(pid)", qos: .userInitiated)
 }

 fileprivate func start(timeout: TimeInterval, cancellation: ProcessCancellation?) {
  let id = self.id
  let group = self.group
  retainedSelf = self
  queue.async { [weak self] in
   self?.startOnQueue(timeout: timeout)
  }
  cancellation?.register { [weak self] in
   self?.terminate()
  }
  group?.completeSpawn(id, execution: self)
 }

 func terminate() {
  queue.async { [weak self] in
   self?.terminateOnQueue()
  }
 }

 func terminateSynchronously() {
  if beginDeadlineCancellationSynchronously() { return }
  let termDeadline = ProcessInfo.processInfo.systemUptime + 0.04
  while ProcessInfo.processInfo.systemUptime < termDeadline {
   if pollDeadlineCompletionSynchronously() { return }
   usleep(2_000)
  }
  finishDeadlineCancellationSynchronously()
 }

 func beginDeadlineCancellationSynchronously() -> Bool {
  queue.sync {
   guard !completed else { return true }
   let firstInterrupt = !interrupted
   interrupted = true
   timeoutTimer?.cancel()
   timeoutTimer = nil
   if firstInterrupt {
    sendTermSignalOnQueue()
   }
   checkCompletionOnQueue()
   return completed
  }
 }

 func pollDeadlineCompletionSynchronously() -> Bool {
  queue.sync {
   guard !completed else { return true }
   drainReadableBytesOnQueue(maxChunks: Self.maximumChunksPerDrainTurn)
   guard !completed else { return true }
   checkCompletionOnQueue()
   return completed
  }
 }

 func finishDeadlineCancellationSynchronously() {
  queue.sync {
   guard !completed else { return }
   interrupted = true
   sendFinalKillOnQueue()
   cancelSignalTimersOnQueue()
   drainReadableBytesOnQueue(maxChunks: Self.maximumChunksPerDrainTurn)
   guard !completed else { return }
   checkCompletionOnQueue()
  }
  let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.04
  while ProcessInfo.processInfo.systemUptime < reapDeadline {
   let done = queue.sync { () -> Bool in
    guard !completed else { return true }
    drainReadableBytesOnQueue(maxChunks: Self.maximumChunksPerDrainTurn)
    guard !completed else { return true }
    reapProcessOnQueue()
    if processReaped && Darwin.kill(-pid, 0) != 0 {
     finishOnQueue()
     return true
    }
    return completed
   }
   if done { return }
   usleep(2_000)
  }
  queue.sync {
   guard !completed else { return }
   drainReadableBytesOnQueue(maxChunks: Self.maximumChunksPerDrainTurn)
   guard !completed else { return }
   reapProcessOnQueue()
   if !processReaped {
    let orphanPID = self.pid
    DispatchQueue.global(qos: .utility).async {
     var status: Int32 = 0
     _ = Darwin.waitpid(orphanPID, &status, 0)
    }
   }
   finishOnQueue()
  }
 }

 private func startOnQueue(timeout: TimeInterval) {
  let fd = self.readFD
  let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
  readSource.setEventHandler { [weak self] in
   guard let self, !self.completed else { return }
   self.drainReadableBytesOnQueue(maxChunks: Self.maximumChunksPerDrainTurn)
  }
  readSource.setCancelHandler { [weak self] in
   if let self {
    if !self.readFDClosed {
     self.readFDClosed = true
     _ = Darwin.close(fd)
    }
   } else {
    _ = Darwin.close(fd)
   }
  }
  self.readSource = readSource
  readSource.resume()

  let procSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
  procSource.setEventHandler { [weak self] in
   guard let self, !self.completed else { return }
   self.procSource?.cancel()
   self.procSource = nil
   self.checkCompletionOnQueue()
  }
  self.procSource = procSource
  procSource.resume()

  let timer = DispatchSource.makeTimerSource(queue: queue)
  timer.schedule(deadline: .now() + max(0.001, timeout))
  timer.setEventHandler { [weak self] in
   self?.terminateOnQueue()
  }
  self.timeoutTimer = timer
  timer.resume()

  checkCompletionOnQueue()
 }

 private func sendTermSignalOnQueue() {
  guard !completed, !finalKillSent, !processReaped else { return }
  _ = Darwin.kill(-pid, SIGTERM)
  _ = Darwin.kill(pid, SIGTERM)
 }

 private func sendFinalKillOnQueue() {
  guard !completed, !finalKillSent, !processReaped else { return }
  finalKillSent = true
  _ = Darwin.kill(-pid, SIGKILL)
  _ = Darwin.kill(pid, SIGKILL)
 }

 private func cancelSignalTimersOnQueue() {
  timeoutTimer?.cancel(); timeoutTimer = nil
  killTimer?.cancel(); killTimer = nil
  forceTimer?.cancel(); forceTimer = nil
 }

 private func drainReadableBytesOnQueue(maxChunks: Int) {
  var buffer = [UInt8](repeating: 0, count: 65536)
  var chunksRead = 0
  var hitWouldBlock = false
  while chunksRead < maxChunks && !eofReached && !completed && !readFDClosed {
   let count = Darwin.read(readFD, &buffer, buffer.count)
   if count > 0 {
    chunksRead += 1
    let remaining = Self.maximumOutputBytes - outputData.count
    if remaining > 0 {
     outputData.append(contentsOf: buffer.prefix(min(count, remaining)))
    }
   } else if count == 0 {
    eofReached = true
    readSource?.cancel()
    readSource = nil
    checkCompletionOnQueue()
    return
   } else {
    let err = errno
    if err == EINTR { continue }
    if err == EAGAIN || err == EWOULDBLOCK {
     hitWouldBlock = true
     break
    }
    eofReached = true
    readSource?.cancel()
    readSource = nil
    checkCompletionOnQueue()
    return
   }
  }
  if !hitWouldBlock && !eofReached && !completed && !readFDClosed && !drainContinuationScheduled {
   drainContinuationScheduled = true
   queue.async { [weak self] in
    guard let self else { return }
    self.drainContinuationScheduled = false
    guard !self.completed, !self.eofReached else { return }
    self.drainReadableBytesOnQueue(maxChunks: Self.maximumChunksPerDrainTurn)
   }
  }
 }

 private func reapProcessOnQueue() {
  guard !processReaped else { return }
  var status: Int32 = 0
  let waited = Darwin.waitpid(pid, &status, WNOHANG)
  if waited == pid {
   processReaped = true
   let signalCode = status & 0x7f
   if signalCode == 0 {
    exitCode = (status >> 8) & 0xff
    terminationSignal = nil
   } else {
    exitCode = signalCode
    terminationSignal = signalCode
   }
   procSource?.cancel()
   procSource = nil
  } else if waited == -1 && errno == ECHILD {
   processReaped = true
   procSource?.cancel()
   procSource = nil
  }
 }

 private func terminateOnQueue() {
  guard !completed else { return }
  let firstInterrupt = !interrupted
  interrupted = true
  timeoutTimer?.cancel()
  timeoutTimer = nil
  if firstInterrupt {
   sendTermSignalOnQueue()
  }
  checkCompletionOnQueue()
  guard !completed, firstInterrupt else { return }

  let killTimer = DispatchSource.makeTimerSource(queue: queue)
  killTimer.schedule(deadline: .now() + 0.12)
  killTimer.setEventHandler { [weak self] in
   guard let self, !self.completed else { return }
   self.sendFinalKillOnQueue()
   self.checkCompletionOnQueue()
  }
  self.killTimer = killTimer
  killTimer.resume()

  let forceTimer = DispatchSource.makeTimerSource(queue: queue)
  forceTimer.schedule(deadline: .now() + 0.22)
  forceTimer.setEventHandler { [weak self] in
   guard let self, !self.completed else { return }
   self.sendFinalKillOnQueue()
   self.cancelSignalTimersOnQueue()
   self.drainReadableBytesOnQueue(maxChunks: Self.maximumChunksPerDrainTurn)
   guard !self.completed else { return }
   self.reapProcessOnQueue()
   if !self.processReaped {
    let orphanPID = self.pid
    DispatchQueue.global(qos: .utility).async {
     var status: Int32 = 0
     _ = Darwin.waitpid(orphanPID, &status, 0)
    }
   }
   self.finishOnQueue()
  }
  self.forceTimer = forceTimer
  forceTimer.resume()
 }

 private func checkCompletionOnQueue() {
  guard !completed else { return }
  if !interrupted {
   // Normal phase: EOF alone is not process exit. Keep timeoutTimer active until
   // the leader process has also exited and been reaped.
   guard eofReached else { return }
   reapProcessOnQueue()
   if processReaped {
    finishOnQueue()
   } else {
    ensureExitPollTimerOnQueue()
   }
   return
  }
  // Interrupted phase: preserve kernel ownership of leader PID/PGID and keep
  // killTimer/forceTimer active until the final SIGKILL has been sent.
  guard finalKillSent, eofReached else { return }
  reapProcessOnQueue()
  if processReaped {
   if Darwin.kill(-pid, 0) == 0 {
    ensureExitPollTimerOnQueue()
    return
   }
   finishOnQueue()
   return
  }
  ensureExitPollTimerOnQueue()
 }

 private func ensureExitPollTimerOnQueue() {
  guard exitPollTimer == nil, !completed else { return }
  let poll = DispatchSource.makeTimerSource(queue: queue)
  poll.schedule(deadline: .now() + 0.005, repeating: 0.005)
  poll.setEventHandler { [weak self] in
   self?.checkCompletionOnQueue()
  }
  exitPollTimer = poll
  poll.resume()
 }

 private func finishOnQueue() {
  guard !completed else { return }
  completed = true
  group?.unregister(id)
  cancelSignalTimersOnQueue()
  exitPollTimer?.cancel(); exitPollTimer = nil
  procSource?.cancel(); procSource = nil
  readSource?.cancel(); readSource = nil
  let signal = interrupted ? (terminationSignal ?? Int32(SIGTERM)) : terminationSignal
  let reason: ProcessTerminationReason = signal != nil ? .uncaughtSignal : .exit
  let code = interrupted ? (exitCode != 0 ? exitCode : Int32(SIGTERM)) : exitCode
  let output = String(decoding: outputData, as: UTF8.self)
  resumeOnce(.success(CommandResult(code: code, output: output, terminationReason: reason, terminationSignal: signal)))
  queue.async { [weak self] in
   self?.retainedSelf = nil
  }
 }

 private func resumeOnce(_ result: Result<CommandResult, Error>) {
  resumeLock.lock()
  let pending = continuation
  continuation = nil
  resumeLock.unlock()
  pending?.resume(with: result)
 }
}

public enum ProcessRunner {
 @TaskLocal public static var currentGroup: ProcessGroupCancellation?

 public static func run(_ executable: URL, _ args: [String], timeout: TimeInterval = 20, cancellable: Bool = true) async throws -> CommandResult {
  let group = currentGroup
  if let group, !group.beginSpawn() {
   return CommandResult(code: Int32(SIGTERM), output: "", terminationReason: .uncaughtSignal, terminationSignal: Int32(SIGTERM))
  }
  let cancellation = cancellable ? ProcessCancellation() : nil
  return try await withTaskCancellationHandler(operation: {
   try await withCheckedThrowingContinuation { continuation in
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
     group?.completeSpawn(UUID(), execution: nil)
     continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(isDirectory.boolValue ? EACCES : ENOENT)))
     return
    }
    var pipeFDs: [Int32] = [-1, -1]
    guard Darwin.pipe(&pipeFDs) == 0 else {
     group?.completeSpawn(UUID(), execution: nil)
     continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
     return
    }
    let readFD = pipeFDs[0]
    let writeFD = pipeFDs[1]
    _ = Darwin.fcntl(readFD, F_SETFD, FD_CLOEXEC)
    _ = Darwin.fcntl(writeFD, F_SETFD, FD_CLOEXEC)
    let flags = Darwin.fcntl(readFD, F_GETFL)
    if flags >= 0 {
     _ = Darwin.fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
    }

    var fileActions: posix_spawn_file_actions_t? = nil
    var attr: posix_spawnattr_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    posix_spawnattr_init(&attr)
    defer {
     posix_spawn_file_actions_destroy(&fileActions)
     posix_spawnattr_destroy(&attr)
    }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attr, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)

    let argvStrings = [executable.path] + args
    let cArgs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
    let envStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
    let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
    defer {
     for ptr in cArgs where ptr != nil { free(ptr) }
     for ptr in cEnv where ptr != nil { free(ptr) }
    }
    var pid: pid_t = 0
    let spawnErr = cArgs.withUnsafeBufferPointer { argBuffer in
     cEnv.withUnsafeBufferPointer { envBuffer in
      posix_spawn(&pid, executable.path, &fileActions, &attr, argBuffer.baseAddress, envBuffer.baseAddress)
     }
    }
    _ = Darwin.close(writeFD)
    if spawnErr != 0 {
     _ = Darwin.close(readFD)
     group?.completeSpawn(UUID(), execution: nil)
     continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(spawnErr)))
     return
    }
    let execution = ProcessExecution(pid: pid, readFD: readFD, group: group, continuation: continuation)
    execution.start(timeout: timeout, cancellation: cancellation)
   }
  }, onCancel: {
   cancellation?.cancel()
  })
 }
}

public struct ADB {
 public let executable: URL
 public init(executable: URL) { self.executable = executable }
 public func run(_ serial: String? = nil, _ args: [String], timeout: TimeInterval = 20, cancellable:Bool = false) async throws -> String {
  let arguments = (serial.map { ["-s",$0] } ?? []) + args
  let result = try await ProcessRunner.run(executable, arguments, timeout: timeout,cancellable:cancellable)
  guard result.code == 0, result.terminationReason == .exit else {
   let code = Self.classify(result)
   let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
   let termDesc = result.terminationReason == .uncaughtSignal ? "signal=\(result.terminationSignal ?? result.code)" : "exit=\(result.code)"
   throw LinkError.failure(code, detail.isEmpty ? "adb \(termDesc) (\(args.first ?? "cmd"))" : detail)
  }
  return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
 }
 public static func ownsMapping(_ text:String,serial:String,local:String,remote:String)->Bool {
  text.split(separator:"\n").contains {line in let f=line.split(whereSeparator:{$0.isWhitespace}).map(String.init);return f.count>=3 && f[0]==serial && f[1]==local && f[2]==remote}
 }
 public static func classify(_ result: CommandResult) -> String {
  classify(
   result.output,
   exitCode: result.code,
   terminationReason: result.terminationReason,
   terminationSignal: result.terminationSignal
  )
 }
 public static func classify(
  _ output: String,
  exitCode: Int32 = -1,
  terminationReason: ProcessTerminationReason = .exit,
  terminationSignal: Int32? = nil
 ) -> String {
  let s=output.lowercased()
  if s.contains("update_incompatible") { return "INSTALL_SIGNATURE_CONFLICT" }
  if s.contains("version_downgrade") { return "INSTALL_DOWNGRADE" }
  if s.contains("user_restricted") || s.contains("canceled by user") || s.contains("cancelled") { return "INSTALL_DENIED" }
  if s.contains("unauthorized") { return "USB_UNAUTHORIZED" }
  if s.contains("offline") || s.contains("no devices") || s.contains("not found") { return "DEVICE_DISCONNECTED" }
  if s.contains("failed to start daemon") || s.contains("error writing ack") || s.contains("cannot connect to daemon") || s.contains("failed to check server version") || s.contains("connection reset by peer") {
   return "ADB_DAEMON_START_FAILED"
  }
  let sig = terminationSignal ?? (terminationReason == .uncaughtSignal ? exitCode : nil)
  if terminationReason == .uncaughtSignal, let sig {
   return sig == SIGABRT ? "ADB_PROCESS_ABORTED" : "ADB_PROCESS_SIGNALLED"
  }
  return "ADB_FAILED"
 }
 public static func devices(_ text: String) -> [(String,String)] {
  text.split(separator:"\n").compactMap { line in
   let f=line.split(whereSeparator: { $0.isWhitespace }); guard f.count>=2, ["device","offline","unauthorized"].contains(String(f[1])) else { return nil }
   return (String(f[0]),String(f[1]))
  }
 }
}
