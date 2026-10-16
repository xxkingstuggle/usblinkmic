import Foundation
import Network
import Contracts

public final class AudioReceiver: @unchecked Sendable {
 private let queue=DispatchQueue(label:"usblinkmic.audio")
 private var listener:NWListener?
 private var connection:NWConnection?
 private var buffer=Data()
 private var header=false
 private var decoder=FrameDecoder()
 private var active=false
 public init() {}
 public func start(settings: Settings, session: String, onFrame:@escaping @Sendable(Data)->Void, onError:@escaping @Sendable(String)->Void) throws {
  stop(); active=true
  let parameters=NWParameters.tcp
  parameters.requiredLocalEndpoint = .hostPort(host:NWEndpoint.Host(settings.listenAddress),port:NWEndpoint.Port(rawValue:UInt16(settings.audioPort))!)
  let listener=try NWListener(using:parameters); self.listener=listener
  listener.stateUpdateHandler = { state in if case .failed(let e)=state {onError("LISTEN_FAILED: \(e)")} }
  listener.newConnectionHandler = { [weak self] c in
   guard let self=self else {c.cancel();return}
   guard self.connection==nil else {c.cancel();return}
   self.connection=c; self.header=false; self.buffer=Data();self.decoder=FrameDecoder()
   c.start(queue:self.queue)
   self.receive(c,settings:settings,session:session,onFrame:onFrame,onError:onError)
  }
  listener.start(queue:queue)
 }
 private func receive(_ c:NWConnection,settings:Settings,session:String,onFrame:@escaping @Sendable(Data)->Void,onError:@escaping @Sendable(String)->Void) {
  c.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,done,error in
   guard let self=self,self.active,self.connection===c else{return}
   if let data=data {self.buffer.append(data)}
   do {
    if !self.header {
     if let newline=self.buffer.firstIndex(of:10) {
      guard newline<=8192, let obj=try JSONSerialization.jsonObject(with:self.buffer.prefix(upTo:newline)) as? [String:Any], obj["protocol"] as? Int == Capabilities.protocolVersion, obj["session"] as? String == session, obj["token"] as? String == settings.pairingCode, obj["sampleRate"] as? Int == settings.audio.sampleRate, obj["channels"] as? Int == settings.audio.channels, obj["format"] as? String == settings.audio.format.rawValue, obj["source"] as? String == settings.audio.source.rawValue else {throw LinkError.failure("HANDSHAKE_REJECTED","身份或音频能力不一致")}
      self.buffer=Data(self.buffer.suffix(from:self.buffer.index(after:newline))); self.header=true
      c.send(content:Data("{\"accepted\":true}\n".utf8),completion:.contentProcessed{_ in})
     } else if self.buffer.count>8192 {throw LinkError.failure("HANDSHAKE_TOO_LARGE","握手超长")}
    }
    if self.header {
     let width=settings.audio.format == .i16 ? 2 : 4
     let frames=try self.decoder.append(self.buffer,bytesPerFrame:width*settings.audio.channels);self.buffer=Data()
     for frame in frames {onFrame(frame)}
    }
    if let error=error {throw error}
    if done {throw LinkError.failure("INPUT_INTERRUPTED","手机输入已中断")}
    self.receive(c,settings:settings,session:session,onFrame:onFrame,onError:onError)
   } catch {if self.active {onError(error.localizedDescription)};c.cancel();self.connection=nil}
  }
 }
 public func stop() {active=false;listener?.cancel();connection?.cancel();listener=nil;connection=nil}
}
