import Foundation
import Synchronization

/// One producer (session actor), one consumer (HAL render callback).
/// The render path only copies preallocated memory and reads atomics.
final class PCMPlaybackBuffer: @unchecked Sendable {
 let capacity: Int
 private let samples: UnsafeMutablePointer<Float>
 private let writePosition = Atomic<Int>(0)
 private let readPosition = Atomic<Int>(0)
 let consumedSamples = Atomic<Int>(0)
 let callbackCount = Atomic<Int>(0)
 let gainBits = Atomic<UInt32>(Float(1).bitPattern)
 let muted = Atomic<Bool>(false)

 init(capacity: Int) {
  self.capacity=capacity
  samples = .allocate(capacity:capacity)
  samples.initialize(repeating:0,count:capacity)
 }
 deinit { samples.deinitialize(count:capacity);samples.deallocate() }
 var queuedSamples: Int {
  writePosition.load(ordering:.acquiring)-readPosition.load(ordering:.acquiring)
 }
 func write(_ input: [Float]) -> Bool {
  let write=writePosition.load(ordering:.relaxed)
  let read=readPosition.load(ordering:.acquiring)
  guard input.count<=capacity-(write-read) else{return false}
  input.withUnsafeBufferPointer { source in
   guard let base=source.baseAddress else{return}
   let first=min(input.count,capacity-write%capacity)
   samples.advanced(by:write%capacity).update(from:base,count:first)
   if first<input.count {samples.update(from:base.advanced(by:first),count:input.count-first)}
  }
  writePosition.store(write+input.count,ordering:.releasing)
  return true
 }
 func render(into destination: UnsafeMutablePointer<Float>, count: Int) {
  let read=readPosition.load(ordering:.relaxed)
  let write=writePosition.load(ordering:.acquiring)
  let available=min(count,write-read)
  let volume=muted.load(ordering:.relaxed) ? Float(0):Float(bitPattern:gainBits.load(ordering:.relaxed))
  for index in 0..<available {destination[index]=samples[(read+index)%capacity]*volume}
  if available<count {destination.advanced(by:available).update(repeating:0,count:count-available)}
  readPosition.store(read+available,ordering:.releasing)
  consumedSamples.wrappingAdd(available,ordering:.relaxed)
  callbackCount.wrappingAdd(1,ordering:.relaxed)
 }
}
