import Foundation
import Contracts
public struct FrameDecoder {
 private var buffer=Data()
 public init() {}
 public mutating func append(_ data:Data,bytesPerFrame:Int) throws -> [Data] {
  guard bytesPerFrame>0 else{throw LinkError.failure("BAD_FORMAT","每帧字节数无效")}
  buffer.append(data);var frames=[Data]()
  while buffer.count>=4 {
   let length=buffer.prefix(4).reduce(0){($0<<8)|Int($1)}
   guard length>0,length<=Capabilities.maxFrameBytes,length%bytesPerFrame==0 else{throw LinkError.failure("BAD_FRAME","帧长度无效")}
   guard buffer.count>=length+4 else{break}
   frames.append(Data(buffer.dropFirst(4).prefix(length)));buffer=Data(buffer.dropFirst(length+4))
  }
  return frames
 }
}
