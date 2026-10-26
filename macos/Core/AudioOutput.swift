import Foundation
import CoreAudio
import AudioToolbox
import Synchronization
import Contracts

public struct AudioOutputStatistics: Sendable, Equatable {
 public let receivedFrames: Int
 public let enqueuedFrames: Int
 public let renderedFrames: Int
 public let underrunFrames: Int
 public let discardedBacklogFrames: Int
 public let droppedInputFrames: Int
 public let queuedFrames: Int
 public let peakQueuedFrames: Int
 public let renderCallbacks: Int
 public let capacityFrames: Int
 public let targetBufferedFrames: Int

 public static let empty = AudioOutputStatistics(receivedFrames: 0, enqueuedFrames: 0, renderedFrames: 0, underrunFrames: 0, discardedBacklogFrames: 0, droppedInputFrames: 0, queuedFrames: 0, peakQueuedFrames: 0, renderCallbacks: 0, capacityFrames: 0, targetBufferedFrames: 0)
}

/// A single serial producer may use this handle off the main actor. It retains
/// only its original ring, so an in-flight old packet can never enter a new output.
final class AudioOutputInput: @unchecked Sendable {
 private let playback: PCMPlaybackBuffer
 private let outputParameters: AudioParameters
 private let sourceLock = NSLock()
 private var sourceParameters: AudioParameters
 private let active = Atomic<Bool>(true)

 internal init(playback: PCMPlaybackBuffer, parameters: AudioParameters) {
  self.playback = playback
  self.outputParameters = parameters
  self.sourceParameters = parameters
 }

 fileprivate func invalidate() { active.store(false, ordering: .releasing) }

 func updateSourceParameters(_ source: AudioParameters) {
  sourceLock.lock()
  sourceParameters = source
  sourceLock.unlock()
 }

 private func currentSourceParameters() -> AudioParameters {
  sourceLock.lock()
  defer { sourceLock.unlock() }
  return sourceParameters
 }

 func consume(_ data: Data, measure: Bool = false) throws -> (level: Double, trend: [Double]) {
  guard active.load(ordering: .acquiring) else { throw LinkError.failure("OUTPUT_STOPPED", "音频输出已停止") }
  let source = currentSourceParameters()
  let width = source.format == .i16 ? 2 : 4
  let inChannels = source.channels
  let outChannels = outputParameters.channels
  guard inChannels > 0, outChannels > 0 else { throw LinkError.failure("BAD_FRAME", "PCM声道数无效") }
  let inFrames = data.count / (width * inChannels)
  guard inFrames > 0, data.count % (width * inChannels) == 0 else { throw LinkError.failure("BAD_FRAME", "PCM帧未对齐") }
  if inChannels == outChannels && source.sampleRate == outputParameters.sampleRate {
   let result = try data.withUnsafeBytes { raw in
    try playback.writeAndMeasure(sampleCount: inFrames * outChannels, channels: outChannels, measure: measure) { index in
     if width == 2 { return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * width, as: Int16.self))) / 32768 }
     return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * width, as: UInt32.self)))
    }
   }
   return (result.level, result.trend)
  }
  let inRate = max(1, source.sampleRate)
  let outRate = max(1, outputParameters.sampleRate)
  let outFrames = inRate == outRate ? inFrames : max(1, Int((Int64(inFrames) * Int64(outRate)) / Int64(inRate)))
  let result = try data.withUnsafeBytes { raw in
   func sampleAt(frame: Int, channel: Int) -> Float {
    let clampedChannel = min(channel, inChannels - 1)
    let sampleIndex = frame * inChannels + clampedChannel
    if width == 2 {
     return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: sampleIndex * 2, as: Int16.self))) / 32768
    }
    return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: sampleIndex * 4, as: UInt32.self)))
   }
   func channelMappedSample(frame: Int, outChannel: Int) -> Float {
    if inChannels == 2 && outChannels == 1 {
     return 0.5 * (sampleAt(frame: frame, channel: 0) + sampleAt(frame: frame, channel: 1))
    }
    return sampleAt(frame: frame, channel: outChannel)
   }
   return try playback.writeAndMeasure(sampleCount: outFrames * outChannels, channels: outChannels, measure: measure) { index in
    let outFrame = index / outChannels
    let outChannel = index % outChannels
    if inRate == outRate {
     return channelMappedSample(frame: outFrame, outChannel: outChannel)
    }
    let position = Double(outFrame) * Double(inRate) / Double(outRate)
    let f0 = min(inFrames - 1, max(0, Int(position)))
    let f1 = min(inFrames - 1, f0 + 1)
    let fraction = Float(position - Double(f0))
    let s0 = channelMappedSample(frame: f0, outChannel: outChannel)
    let s1 = channelMappedSample(frame: f1, outChannel: outChannel)
    return s0 + (s1 - s0) * fraction
   }
  }
  return (result.level, result.trend)
 }
}

@MainActor public final class AudioOutput {
 private var audioUnit: AudioUnit?
 private var playback: PCMPlaybackBuffer?
 private var parameters: AudioParameters?
 private var input: AudioOutputInput?
 private var activityToken: NSObjectProtocol?
 private var lastStatistics = AudioOutputStatistics.empty
 private var lastSampleRate = 0
 internal var onRestartCurrentDevice: (() throws -> Void)?
 public var gain: Float = 1 { didSet { playback?.gainBits.store(gain.bitPattern,ordering:.relaxed) } }
 public var muted = false { didSet { playback?.muted.store(muted,ordering:.relaxed) } }
 public var renderedFrames: Int { playback?.statistics.renderedFrames ?? 0 }
 public var renderCallbacks: Int { playback?.callbackCount.load(ordering:.relaxed) ?? 0 }
 public var statistics: AudioOutputStatistics {
  guard let value = playback?.statistics else { return lastStatistics }
  return AudioOutputStatistics(receivedFrames: value.receivedFrames, enqueuedFrames: value.enqueuedFrames, renderedFrames: value.renderedFrames, underrunFrames: value.underrunFrames, discardedBacklogFrames: value.discardedBacklogFrames, droppedInputFrames: value.droppedInputFrames, queuedFrames: value.queuedFrames, peakQueuedFrames: value.peakQueuedFrames, renderCallbacks: value.renderCallbacks, capacityFrames: value.capacityFrames, targetBufferedFrames: value.targetBufferedFrames)
 }
 public var diagnostics: String {
  let value = statistics
  let sampleRate = parameters?.sampleRate ?? lastSampleRate
  let queuedMilliseconds = sampleRate > 0 ? value.queuedFrames * 1000 / sampleRate : 0
  let targetMilliseconds = sampleRate > 0 ? value.targetBufferedFrames * 1000 / sampleRate : 0
  return "queuedFrames=\(value.queuedFrames), queuedMs=\(queuedMilliseconds), peakQueuedFrames=\(value.peakQueuedFrames), renderCallbacks=\(value.renderCallbacks), consumedFrames=\(value.renderedFrames), underrunFrames=\(value.underrunFrames), overflowFrames=\(value.droppedInputFrames), backlogDropFrames=\(value.discardedBacklogFrames), targetBufferedMs=\(targetMilliseconds)"
 }
 public init() {}
 deinit {
  input?.invalidate()
  if let token = activityToken { ProcessInfo.processInfo.endActivity(token) }
  if let unit = audioUnit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
 }
 public static func devices() -> [OutputDevice] {
  var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
  var size: UInt32=0
  guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size)==noErr else { return [] }
  var ids=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
  guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&ids)==noErr else { return [] }
  return ids.compactMap { id in
   var streams=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain); var count: UInt32=0
   guard AudioObjectGetPropertyDataSize(id,&streams,0,nil,&count)==noErr, count>0 else { return nil }
   guard let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName) else { return nil }
   return OutputDevice(id:uid,name:name,isVirtual:name.lowercased().contains("blackhole"))
  }
 }
 private static func string(_ id: AudioDeviceID,_ selector: AudioObjectPropertySelector) -> String? {
  var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
  var value: Unmanaged<CFString>?=nil; var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&value)==noErr else { return nil }; return value?.takeRetainedValue() as String?
 }
 private static func deviceID(_ uid: String) -> AudioDeviceID? {
  var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain); var n:UInt32=0
  guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n)==0 else {return nil}
  var ids=[AudioDeviceID](repeating:0,count:Int(n)/4)
  guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n,&ids)==0 else {return nil}
  return ids.first { string($0,kAudioDevicePropertyDeviceUID)==uid }
 }
 private func createAndStartUnit(_ settings: Settings, buffer: PCMPlaybackBuffer) throws -> AudioUnit {
  let requestedDevice: AudioDeviceID?
  if settings.outputUID == "default" {
   var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
   var device:AudioDeviceID=0;var size=UInt32(MemoryLayout<AudioDeviceID>.size)
   requestedDevice=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)==noErr ? device:nil
  }else{requestedDevice=Self.deviceID(settings.outputUID)}
  guard var device=requestedDevice else{throw LinkError.failure("OUTPUT_MISSING","指定输出已离线；重新选择后启动")}
  var description=AudioComponentDescription(componentType:kAudioUnitType_Output,componentSubType:settings.outputUID == "default" ? kAudioUnitSubType_DefaultOutput:kAudioUnitSubType_HALOutput,componentManufacturer:kAudioUnitManufacturer_Apple,componentFlags:0,componentFlagsMask:0)
  guard let component=AudioComponentFindNext(nil,&description) else{throw LinkError.failure("OUTPUT_COMPONENT","系统HAL音频组件不可用")}
  var instance:AudioUnit?
  try Self.check(AudioComponentInstanceNew(component,&instance),"创建HAL输出")
  guard let unit=instance else{throw LinkError.failure("OUTPUT_COMPONENT","创建HAL输出失败")}
  var initialized=false
  do {
   if settings.outputUID != "default" {
    try Self.check(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,UInt32(MemoryLayout<AudioDeviceID>.size)),"选择输出设备")
    var actual=AudioDeviceID();var size=UInt32(MemoryLayout<AudioDeviceID>.size)
    try Self.check(AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actual,&size),"读取输出设备")
    guard actual==device else{throw LinkError.failure("OUTPUT_SELECT_FAILED","系统实际输出与所选设备不一致")}
   }
   let channels=settings.audio.channels
   var format=AudioStreamBasicDescription(mSampleRate:Double(settings.audio.sampleRate),mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:UInt32(channels*4),mFramesPerPacket:1,mBytesPerFrame:UInt32(channels*4),mChannelsPerFrame:UInt32(channels),mBitsPerChannel:32,mReserved:0)
   try Self.check(AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),"设置PCM格式")
   var callback=AURenderCallbackStruct(inputProc:{ref,_,_,_,frames,audioData in
    guard let audioData else{return noErr}
    let buffer=Unmanaged<PCMPlaybackBuffer>.fromOpaque(ref).takeUnretainedValue()
    let buffers=UnsafeMutableAudioBufferListPointer(audioData)
    guard buffers.count==1,let data=buffers[0].mData,buffers[0].mNumberChannels==UInt32(buffer.channels) else{return kAudio_ParamError}
    let count=Int(frames)*buffer.channels
    guard count*MemoryLayout<Float>.size<=Int(buffers[0].mDataByteSize) else{return kAudio_ParamError}
    buffer.render(into:data.assumingMemoryBound(to:Float.self),count:count)
    return noErr
   },inputProcRefCon:Unmanaged.passUnretained(buffer).toOpaque())
   try Self.check(AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,UInt32(MemoryLayout<AURenderCallbackStruct>.size)),"设置渲染回调")
   try Self.check(AudioUnitInitialize(unit),"初始化HAL输出");initialized=true
   try Self.check(AudioOutputUnitStart(unit),"启动HAL输出")
   return unit
  } catch {
   AudioOutputUnitStop(unit)
   if initialized {AudioUnitUninitialize(unit)}
   AudioComponentInstanceDispose(unit)
   throw error
  }
 }
 public func start(_ settings: Settings) throws {
  stop()
  // Keep at most 100 ms queued; the render callback discards any older backlog.
  let channels=settings.audio.channels
  let maximumBufferedFrames=max(1,settings.audio.sampleRate/10)
  let buffer=PCMPlaybackBuffer(capacity:settings.audio.sampleRate*channels,channels:channels,maximumBufferedFrames:maximumBufferedFrames)
  buffer.gainBits.store(Float(settings.gain).bitPattern,ordering:.relaxed);buffer.muted.store(settings.muted,ordering:.relaxed)
  // Keep the callback context alive before the hardware can invoke it.
  playback=buffer;parameters=settings.audio;input=AudioOutputInput(playback:buffer,parameters:settings.audio)
  do {
   let unit=try createAndStartUnit(settings,buffer:buffer)
   audioUnit=unit;gain=Float(settings.gain);muted=settings.muted
   if activityToken == nil {
    activityToken=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"USB LinkMic 实时音频输出")
   }
  } catch {
   input?.invalidate();input=nil;playback=nil;parameters=nil
   throw error
  }
 }
 public func restartCurrentDevice(_ settings: Settings) throws {
  if let hook = onRestartCurrentDevice {
   try hook()
   return
  }
  guard let buffer = playback, input != nil else {
   throw LinkError.failure("OUTPUT_STOPPED","音频输出未启动")
  }
  if let unit = audioUnit {
   AudioOutputUnitStop(unit)
   AudioUnitUninitialize(unit)
   AudioComponentInstanceDispose(unit)
   audioUnit = nil
  }
  var currentSettings = settings
  if let activeAudio = parameters {
   currentSettings.audio = activeAudio
  }
  let unit = try createAndStartUnit(currentSettings, buffer: buffer)
  audioUnit = unit
  gain = Float(settings.gain)
  muted = settings.muted
  if activityToken == nil {
   activityToken = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"USB LinkMic 实时音频输出")
  }
 }
 private static func check(_ code:OSStatus,_ stage:String) throws {
  guard code==noErr else{throw LinkError.failure("OUTPUT_HAL_FAILED","\(stage)失败，OSStatus=\(code)")}
 }
 func makeInput() throws -> AudioOutputInput {
  guard let input else {throw LinkError.failure("OUTPUT_STOPPED","音频输出未启动")}
  return input
 }
 public func stop() {
  input?.invalidate()
  if let token = activityToken {
   ProcessInfo.processInfo.endActivity(token)
   activityToken = nil
  }
  if let unit=audioUnit {AudioOutputUnitStop(unit);lastStatistics=statistics;lastSampleRate=parameters?.sampleRate ?? lastSampleRate;AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit)}
  else {lastStatistics=statistics;lastSampleRate=parameters?.sampleRate ?? lastSampleRate}
  audioUnit=nil;playback=nil;parameters=nil;input=nil
 }
}
