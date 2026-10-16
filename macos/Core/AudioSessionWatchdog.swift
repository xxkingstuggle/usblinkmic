import Foundation

/// Only the current session may arm or refresh the audio deadline.
struct AudioSessionWatchdog {
 enum Failure: String { case interrupted = "INPUT_INTERRUPTED", firstFrame = "FIRST_FRAME_TIMEOUT" }
 private(set) var sessionID: String?
 private var recordingAt: TimeInterval?
 private var lastFrameAt: TimeInterval?
 mutating func begin(_ id: String) { sessionID=id; recordingAt=nil; lastFrameAt=nil }
 mutating func stop(_ id: String) { guard sessionID==id else{return};sessionID=nil;recordingAt=nil;lastFrameAt=nil }
 mutating func recording(_ id: String, now: TimeInterval) { guard sessionID==id else{return};if recordingAt==nil {recordingAt=now} }
 mutating func frame(_ id: String, now: TimeInterval) { guard sessionID==id else{return};lastFrameAt=now }
 func failure(_ id: String, now: TimeInterval) -> Failure? {
  guard sessionID==id else{return nil}
  if let lastFrameAt { return now-lastFrameAt>3 ? .interrupted:nil }
  if let recordingAt { return now-recordingAt>15 ? .firstFrame:nil }
  return nil
 }
}
