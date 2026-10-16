import Foundation
import Darwin

public struct CommandResult: Sendable { public let code: Int32; public let output: String }
public enum LinkError: LocalizedError {
 case failure(String, String)
 public var errorDescription: String? { if case let .failure(code, message) = self { return "[\(code)] \(message)" }; return nil }
}
private final class ProcessCancellation: @unchecked Sendable {
 private let lock=NSLock()
 private var process:Process?
 private var cancelled=false
 func register(_ p:Process) {lock.lock();process=p;let stop=cancelled;lock.unlock();if stop{terminate(p)}}
 func cancel(){lock.lock();cancelled=true;let p=process;lock.unlock();if let p=p {terminate(p)}}
 private func terminate(_ p:Process){if p.isRunning {p.terminate();DispatchQueue.global().asyncAfter(deadline:.now()+1){if p.isRunning {kill(p.processIdentifier,SIGKILL)}}}}
}
public enum ProcessRunner {
 public static func run(_ executable: URL, _ args: [String], timeout: TimeInterval = 20, cancellable:Bool = true) async throws -> CommandResult {
  let cancellation=cancellable ? ProcessCancellation():nil
  return try await withTaskCancellationHandler(operation:{
   try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos:.userInitiated).async {
     let p=Process();let pipe=Pipe();p.executableURL=executable;p.arguments=args;p.standardOutput=pipe;p.standardError=pipe
     do {
      try p.run();cancellation?.register(p)
      let timer=DispatchSource.makeTimerSource(queue:.global());timer.schedule(deadline:.now()+timeout)
      timer.setEventHandler{if p.isRunning{p.terminate();DispatchQueue.global().asyncAfter(deadline:.now()+1){if p.isRunning{kill(p.processIdentifier,SIGKILL)}}}};timer.resume()
      let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();timer.cancel()
      continuation.resume(returning:CommandResult(code:p.terminationStatus,output:String(decoding:data.prefix(2_000_000),as:UTF8.self)))
     }catch{continuation.resume(throwing:error)}
    }
   }
  },onCancel:{cancellation?.cancel()})
 }
}

public struct ADB {
 public let executable: URL
 public init(executable: URL) { self.executable = executable }
 public func run(_ serial: String? = nil, _ args: [String], timeout: TimeInterval = 20, cancellable:Bool = false) async throws -> String {
  let arguments = (serial.map { ["-s",$0] } ?? []) + args
  let result = try await ProcessRunner.run(executable, arguments, timeout: timeout,cancellable:cancellable)
  guard result.code == 0 else { throw LinkError.failure(Self.classify(result.output), result.output) }
  return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
 }
 public static func ownsMapping(_ text:String,serial:String,local:String,remote:String)->Bool {
  text.split(separator:"\n").contains {line in let f=line.split(whereSeparator:{$0.isWhitespace}).map(String.init);return f.count>=3 && f[0]==serial && f[1]==local && f[2]==remote}
 }
 public static func classify(_ output: String) -> String {
  let s=output.lowercased()
  if s.contains("update_incompatible") { return "INSTALL_SIGNATURE_CONFLICT" }
  if s.contains("version_downgrade") { return "INSTALL_DOWNGRADE" }
  if s.contains("user_restricted") || s.contains("canceled by user") || s.contains("cancelled") { return "INSTALL_DENIED" }
  if s.contains("unauthorized") { return "USB_UNAUTHORIZED" }
  if s.contains("offline") || s.contains("no devices") || s.contains("not found") { return "DEVICE_DISCONNECTED" }
  return "ADB_FAILED"
 }
 public static func devices(_ text: String) -> [(String,String)] {
  text.split(separator:"\n").compactMap { line in
   let f=line.split(whereSeparator: { $0.isWhitespace }); guard f.count>=2, ["device","offline","unauthorized"].contains(String(f[1])) else { return nil }
   return (String(f[0]),String(f[1]))
  }
 }
}
