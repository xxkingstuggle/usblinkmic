import Foundation
import CoreAudio
import AudioToolbox
import Contracts

@MainActor public final class AudioOutput {
 private var audioUnit: AudioUnit?
 private var playback: PCMPlaybackBuffer?
 private var parameters: AudioParameters?
 public var gain: Float = 1 { didSet { playback?.gainBits.store(gain.bitPattern,ordering:.relaxed) } }
 public var muted = false { didSet { playback?.muted.store(muted,ordering:.relaxed) } }
 public var renderedFrames: Int { guard let playback,let parameters else{return 0};return playback.consumedSamples.load(ordering:.relaxed)/parameters.channels }
 public var renderCallbacks: Int { playback?.callbackCount.load(ordering:.relaxed) ?? 0 }
 public init() {}
 deinit {if let unit=audioUnit {AudioOutputUnitStop(unit);AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit)}}
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
 public func start(_ settings: Settings) throws {
  stop()
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
   // Bounded by samples/time, not by how TCP groups packets into receive callbacks.
   let buffer=PCMPlaybackBuffer(capacity:settings.audio.sampleRate*channels)
   buffer.gainBits.store(Float(settings.gain).bitPattern,ordering:.relaxed);buffer.muted.store(settings.muted,ordering:.relaxed)
   var callback=AURenderCallbackStruct(inputProc:{ref,_,_,_,frames,audioData in
    guard let audioData else{return noErr}
    let buffer=Unmanaged<PCMPlaybackBuffer>.fromOpaque(ref).takeUnretainedValue()
    let buffers=UnsafeMutableAudioBufferListPointer(audioData)
    guard buffers.count==1,let data=buffers[0].mData else{return kAudio_ParamError}
    let count=Int(frames)*Int(buffers[0].mNumberChannels)
    guard count*MemoryLayout<Float>.size<=Int(buffers[0].mDataByteSize) else{return kAudio_ParamError}
    buffer.render(into:data.assumingMemoryBound(to:Float.self),count:count)
    return noErr
   },inputProcRefCon:Unmanaged.passUnretained(buffer).toOpaque())
   try Self.check(AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,UInt32(MemoryLayout<AURenderCallbackStruct>.size)),"设置渲染回调")
   try Self.check(AudioUnitInitialize(unit),"初始化HAL输出");initialized=true
   // Keep the callback context alive before the hardware can invoke it.
   playback=buffer;parameters=settings.audio
   try Self.check(AudioOutputUnitStart(unit),"启动HAL输出")
   audioUnit=unit;gain=Float(settings.gain);muted=settings.muted
  }catch{
   AudioOutputUnitStop(unit)
   if initialized {AudioUnitUninitialize(unit)}
   AudioComponentInstanceDispose(unit);playback=nil;parameters=nil
   throw error
  }
 }
 private static func check(_ code:OSStatus,_ stage:String) throws {
  guard code==noErr else{throw LinkError.failure("OUTPUT_HAL_FAILED","\(stage)失败，OSStatus=\(code)")}
 }
 public func consume(_ data: Data, parameters: AudioParameters) throws -> (Double,[Double]) {
  guard let playback,self.parameters==parameters else{throw LinkError.failure("OUTPUT_STOPPED","音频输出未启动或参数已改变")}
  let width=parameters.format == .i16 ? 2:4
  let channels=parameters.channels;let frames=data.count/(width*channels)
  guard frames>0,data.count%(width*channels)==0 else{throw LinkError.failure("BAD_FRAME","PCM帧未对齐")}
  var decoded=[Float](repeating:0,count:frames*channels)
  var sum=0.0;var trend=[Double]();trend.reserveCapacity(64)
  try data.withUnsafeBytes { raw in
   for index in decoded.indices {
    let sample:Float
    if width==2 {sample=Float(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:index*width,as:Int16.self)))/32768}
    else{sample=Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:index*width,as:UInt32.self)))}
    guard sample.isFinite else{throw LinkError.failure("BAD_FRAME","PCM包含非有限数值")}
    decoded[index]=sample;sum+=Double(sample*sample)
    if index%channels==0,(index/channels)%max(1,frames/64)==0,trend.count<64 {trend.append(Double(sample))}
   }
  }
  guard playback.write(decoded) else{throw LinkError.failure("OUTPUT_BACKPRESSURE","硬件输出未及时消耗PCM：缓存已满；renderCallbacks=\(renderCallbacks), renderedFrames=\(renderedFrames)")}
  return (sqrt(sum/Double(decoded.count)),trend)
 }
 public func stop() {
  if let unit=audioUnit {AudioOutputUnitStop(unit);AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit)}
  audioUnit=nil;playback=nil;parameters=nil
 }
}
