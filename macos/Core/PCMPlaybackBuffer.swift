import Foundation
import Synchronization
import Contracts

/// One producer (the serial receiver queue), one consumer (the HAL render callback).
/// The render path only reads atomics and copies from preallocated storage.
final class PCMPlaybackBuffer: @unchecked Sendable {
 let capacity: Int
 let channels: Int
 let maximumBufferedSamples: Int
 private let samples: UnsafeMutablePointer<Float>
 private let writePosition = Atomic<Int>(0)
 private let readPosition = Atomic<Int>(0)
 private let receivedSamples = Atomic<Int>(0)
 private let enqueuedSamples = Atomic<Int>(0)
 let consumedSamples = Atomic<Int>(0)
 private let underrunSamples = Atomic<Int>(0)
 private let discardedBacklogSamples = Atomic<Int>(0)
 private let droppedInputSamples = Atomic<Int>(0)
 private let peakQueuedSamples = Atomic<Int>(0)
 let callbackCount = Atomic<Int>(0)
 let gainBits = Atomic<UInt32>(Float(1).bitPattern)
 let muted = Atomic<Bool>(false)

 init(capacity: Int, channels: Int = 1, maximumBufferedFrames: Int? = nil) {
  let safeChannels = max(1, channels)
  let requestedCapacity = max(safeChannels, capacity)
  let alignedCapacity = max(safeChannels, requestedCapacity / safeChannels * safeChannels)
  let requestedFrames = max(1, maximumBufferedFrames ?? (alignedCapacity / safeChannels / 10))
  let bufferedFrames = min(alignedCapacity / safeChannels, requestedFrames)
  self.channels = safeChannels
  self.capacity = alignedCapacity
  self.maximumBufferedSamples = bufferedFrames * safeChannels
  samples = .allocate(capacity: alignedCapacity)
  samples.initialize(repeating: 0, count: alignedCapacity)
 }

 deinit {
  samples.deinitialize(count: capacity)
  samples.deallocate()
 }

 var queuedSamples: Int {
  let read = readPosition.load(ordering: .acquiring)
  let write = writePosition.load(ordering: .acquiring)
  return min(capacity, max(0, write - read))
 }

 /// Compatibility entry point for callers that already hold decoded samples.
 /// The production receive path uses writeAndMeasure to avoid a decoded copy.
 func write(_ input: [Float]) -> Bool {
  guard input.count % channels == 0 else { return false }
  let write = writePosition.load(ordering: .relaxed)
  let read = readPosition.load(ordering: .acquiring)
  let queuedBeforeWrite = max(0, write - read)
  guard input.count <= capacity - min(capacity, queuedBeforeWrite) else {
   receivedSamples.wrappingAdd(input.count, ordering: .relaxed)
   droppedInputSamples.wrappingAdd(input.count, ordering: .relaxed)
   return false
  }

  let start = write % capacity
  for index in input.indices {
   let destinationIndex = start + index
   samples[destinationIndex < capacity ? destinationIndex : destinationIndex - capacity] = input[index]
  }
  receivedSamples.wrappingAdd(input.count, ordering: .relaxed)
  if !input.isEmpty {
   let newWrite = write + input.count
   writePosition.store(newWrite, ordering: .releasing)
   enqueuedSamples.wrappingAdd(input.count, ordering: .relaxed)
   let queuedAfterWrite = min(capacity, max(0, newWrite - read))
   let previousPeak = peakQueuedSamples.load(ordering: .relaxed)
   if queuedAfterWrite > previousPeak {
    peakQueuedSamples.store(queuedAfterWrite, ordering: .relaxed)
   }
  }
  return true
 }

 /// Decodes and measures an input packet in one pass. A full ring drops this packet
 /// and records it, but never advances the consumer cursor or fails the audio session.
 func writeAndMeasure(sampleCount: Int, channels inputChannels: Int, measure: Bool = true, sampleAt: (Int) throws -> Float) throws -> (accepted: Bool, level: Double, trend: [Double]) {
  guard sampleCount > 0, inputChannels == channels, sampleCount % channels == 0 else {
   throw LinkError.failure("BAD_FRAME", "PCM帧未对齐")
  }

  let write = writePosition.load(ordering: .relaxed)
  let read = readPosition.load(ordering: .acquiring)
  let queuedBeforeWrite = max(0, write - read)
  let canStore = sampleCount <= capacity - min(capacity, queuedBeforeWrite)
  let start = write % capacity
  let frames = sampleCount / channels
  let trendStride = max(1, frames / 64)
  var trend: [Double] = []
  if measure { trend.reserveCapacity(min(64, (frames + trendStride - 1) / trendStride)) }
  var sumSquares = 0.0

  for index in 0..<sampleCount {
   let sample = try sampleAt(index)
   guard sample.isFinite else { throw LinkError.failure("BAD_FRAME", "PCM包含非有限数值") }
   if measure {
    sumSquares += Double(sample) * Double(sample)
    if index % channels == 0, (index / channels) % trendStride == 0, trend.count < 64 {
     trend.append(Double(sample))
    }
   }
   if canStore {
    let destinationIndex = start + index
    samples[destinationIndex < capacity ? destinationIndex : destinationIndex - capacity] = sample
   }
  }

  receivedSamples.wrappingAdd(sampleCount, ordering: .relaxed)
  if canStore {
   let newWrite = write + sampleCount
   writePosition.store(newWrite, ordering: .releasing)
   enqueuedSamples.wrappingAdd(sampleCount, ordering: .relaxed)
   let queuedAfterWrite = min(capacity, max(0, newWrite - read))
   let previousPeak = peakQueuedSamples.load(ordering: .relaxed)
   if queuedAfterWrite > previousPeak {
    peakQueuedSamples.store(queuedAfterWrite, ordering: .relaxed)
   }
  } else {
   droppedInputSamples.wrappingAdd(sampleCount, ordering: .relaxed)
  }

  return (canStore, measure ? sqrt(sumSquares / Double(sampleCount)) : 0, trend)
 }

 func render(into destination: UnsafeMutablePointer<Float>, count: Int) {
  guard count >= 0 else { return }
  let initialRead = readPosition.load(ordering: .relaxed)
  let write = writePosition.load(ordering: .acquiring)
  var read = initialRead
  var available = min(capacity, max(0, write - read))

  // The render thread owns readPosition. Prune stale audio here so the producer
  // never races the consumer by moving its cursor to make room.
  if available > maximumBufferedSamples {
   let excess = available - maximumBufferedSamples
   let discard = (excess / channels) * channels
   if discard > 0 {
    read += discard
    available -= discard
    readPosition.store(read, ordering: .releasing)
    discardedBacklogSamples.wrappingAdd(discard, ordering: .relaxed)
   }
  }

  let rendered = min(count, available)
  let volume = muted.load(ordering: .relaxed) ? Float(0) : Float(bitPattern: gainBits.load(ordering: .relaxed))
  let start = read % capacity
  for index in 0..<rendered {
   let sourceIndex = start + index
   destination[index] = samples[sourceIndex < capacity ? sourceIndex : sourceIndex - capacity] * volume
  }
  if rendered < count {
   destination.advanced(by: rendered).update(repeating: 0, count: count - rendered)
  }

  readPosition.store(read + rendered, ordering: .releasing)
  consumedSamples.wrappingAdd(rendered, ordering: .relaxed)
  underrunSamples.wrappingAdd(count - rendered, ordering: .relaxed)
  callbackCount.wrappingAdd(1, ordering: .relaxed)
 }

 var statistics: PCMPlaybackBufferStatistics {
  let queued = queuedSamples / channels
  return PCMPlaybackBufferStatistics(
   receivedFrames: receivedSamples.load(ordering: .relaxed) / channels,
   enqueuedFrames: enqueuedSamples.load(ordering: .relaxed) / channels,
   renderedFrames: consumedSamples.load(ordering: .relaxed) / channels,
   underrunFrames: underrunSamples.load(ordering: .relaxed) / channels,
   discardedBacklogFrames: discardedBacklogSamples.load(ordering: .relaxed) / channels,
   droppedInputFrames: droppedInputSamples.load(ordering: .relaxed) / channels,
   queuedFrames: queued,
   peakQueuedFrames: peakQueuedSamples.load(ordering: .relaxed) / channels,
   renderCallbacks: callbackCount.load(ordering: .relaxed),
   capacityFrames: capacity / channels,
   targetBufferedFrames: maximumBufferedSamples / channels
  )
 }
}

struct PCMPlaybackBufferStatistics: Sendable {
 let receivedFrames: Int
 let enqueuedFrames: Int
 let renderedFrames: Int
 let underrunFrames: Int
 let discardedBacklogFrames: Int
 let droppedInputFrames: Int
 let queuedFrames: Int
 let peakQueuedFrames: Int
 let renderCallbacks: Int
 let capacityFrames: Int
 let targetBufferedFrames: Int
}
