import Foundation
import Darwin
public enum ControlClient {
 public static func request(port:Int, body:[String:Any]) async throws -> [String:Any] {
  let data=try JSONSerialization.data(withJSONObject:body)+Data([10])
  let response:Data = try await withCheckedThrowingContinuation { continuation in
   DispatchQueue.global().async {
    let fd=socket(AF_INET,SOCK_STREAM,0); guard fd>=0 else {continuation.resume(throwing:LinkError.failure("CONTROL_SOCKET","无法创建控制通道"));return}
    defer {Darwin.close(fd)}
    var tv=timeval(tv_sec:3,tv_usec:0); setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,socklen_t(MemoryLayout.size(ofValue:tv)));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&tv,socklen_t(MemoryLayout.size(ofValue:tv)))
    var noSig:Int32=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSig,4)
    var address=sockaddr_in();address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(port).bigEndian;address.sin_addr.s_addr=inet_addr("127.0.0.1")
    let connected=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))} }
    guard connected==0 else {continuation.resume(throwing:LinkError.failure("CONTROL_CONNECT","手机控制通道尚未就绪"));return}
    var sent=0
    while sent<data.count {let n=data.withUnsafeBytes {Darwin.send(fd,$0.baseAddress!.advanced(by:sent),data.count-sent,0)};if n<=0 {continuation.resume(throwing:LinkError.failure("CONTROL_SEND","控制命令发送失败"));return};sent+=n}
    var received=Data();var buf=[UInt8](repeating:0,count:1024)
    while received.count<=8192 {let n=Darwin.recv(fd,&buf,buf.count,0);if n<=0 {break};received.append(contentsOf:buf.prefix(n));if received.contains(10){break}}
    guard received.count<=8192,let end=received.firstIndex(of:10) else {continuation.resume(throwing:LinkError.failure("CONTROL_TIMEOUT","手机状态响应超时"));return}
    continuation.resume(returning:received.prefix(upTo:end))
   }
  }
  guard let object=try JSONSerialization.jsonObject(with:response) as? [String:Any] else {throw LinkError.failure("CONTROL_INVALID","状态响应无效")};return object
 }
}
