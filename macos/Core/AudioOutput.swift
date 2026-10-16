import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Contracts

@MainActor public final class AudioOutput {
 private let engine = AVAudioEngine()
 private let player = AVAudioPlayerNode()
 private var connected = false
 private var pending = 0
 public var gain: Float = 1 { didSet { player.volume = muted ? 0 : gain } }
 public var muted = false { didSet { player.volume = muted ? 0 : gain } }
 public init() { engine.attach(player) }
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
  let requestedDevice:AudioDeviceID?
  if settings.outputUID == "default" {
   var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
   var device:AudioDeviceID=0;var size=UInt32(MemoryLayout<AudioDeviceID>.size)
   requestedDevice=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)==noErr ? device:nil
  }else{requestedDevice=Self.deviceID(settings.outputUID)}
  do {
   guard var id=requestedDevice, let unit=engine.outputNode.audioUnit else { throw LinkError.failure("OUTPUT_MISSING","指定输出已离线；重新选择后启动") }
   guard AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,UInt32(MemoryLayout.size(ofValue:id)))==noErr else { throw LinkError.failure("OUTPUT_SELECT_FAILED","无法选择指定输出") }
  }
  guard let format=AVAudioFormat(standardFormatWithSampleRate:Double(settings.audio.sampleRate),channels:AVAudioChannelCount(settings.audio.channels)) else { throw LinkError.failure("OUTPUT_FORMAT","不支持的输出格式") }
  engine.connect(player,to:engine.mainMixerNode,format:format); connected=true
  try engine.start(); gain=Float(settings.gain); muted=settings.muted; player.play()
 }
 public func consume(_ data: Data, parameters: AudioParameters) throws -> (Double,[Double]) {
  let width=parameters.format == .i16 ? 2 : 4
  let channels=parameters.channels; let frames=data.count/(width*channels)
  guard frames>0, data.count % (width*channels)==0, let format=AVAudioFormat(standardFormatWithSampleRate:Double(parameters.sampleRate),channels:AVAudioChannelCount(channels)), let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)),let dest=buffer.floatChannelData else {throw LinkError.failure("BAD_FRAME","PCM帧未对齐")}
  var sum=0.0; var trend=[Double](); trend.reserveCapacity(64)
  try data.withUnsafeBytes { raw in
   for i in 0..<frames {
    for c in 0..<channels {
     let offset=(i*channels+c)*width
     let sample: Float
     if width==2 {sample=Float(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:offset,as:Int16.self)))/32768}
     else {sample=Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))}
     guard sample.isFinite else {throw LinkError.failure("BAD_FRAME","PCM包含非有限数值")}
     dest[c][i]=sample; sum+=Double(sample*sample)
     if c==0 && i % max(1,frames/64)==0 && trend.count<64 {trend.append(Double(sample))}
    }
   }
  }
  buffer.frameLength=AVAudioFrameCount(frames)
  guard pending < 16 else { throw LinkError.failure("OUTPUT_UNDERRUN","输出队列无法跟上输入；停止后重试") }
  pending+=1
  player.scheduleBuffer(buffer) { [weak self] in Task { @MainActor in self?.pending=max(0,(self?.pending ?? 1)-1) } }
  return (sqrt(sum/Double(frames*channels)),trend)
 }
 public func stop() { player.stop(); engine.stop(); pending=0; if connected {engine.disconnectNodeOutput(player); connected=false} }
}
