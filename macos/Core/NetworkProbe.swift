import Foundation
public struct NetworkInterface: Equatable, Sendable { public let name:String; public let address:String }
public enum NetworkProbe {
 public static func interfaceNames() async throws -> Set<String> {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/ifconfig"),["-l"],timeout:3)
  guard result.code==0 else{throw LinkError.failure("INTERFACE_SCAN",result.output)}
  return Set(result.output.split(whereSeparator:{$0.isWhitespace}).map(String.init).filter{$0.hasPrefix("en")})
 }
 public static func interfaces() async throws -> [NetworkInterface] {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/ifconfig"),["-a"],timeout:3)
  guard result.code==0 else{throw LinkError.failure("INTERFACE_SCAN",result.output)}
  return parseInterfaces(result.output)
 }
 public static func parseInterfaces(_ text:String)->[NetworkInterface] {
  var current="";var values=[NetworkInterface]()
  for line in text.split(separator:"\n") {
   if !line.hasPrefix("\t"),!line.hasPrefix(" "),let name=line.split(separator:":").first {current=String(name)}
   let fields=line.split(whereSeparator:{$0.isWhitespace})
   if fields.count>1,fields[0]=="inet",current.hasPrefix("en"),fields[1] != "127.0.0.1",!fields[1].hasPrefix("169.254."),fields[1] != "0.0.0.0" {values.append(NetworkInterface(name:current,address:String(fields[1])))}
  }
  return values
 }
 public static func verify(interface:String?=nil) async throws {
  var args=["--silent","--show-error","--connect-timeout","5","--max-time","12","--output","/dev/null","--write-out","%{http_code}","--noproxy","*"]
  if let interface=interface {args += ["--interface",interface]}
  args.append("https://connectivitycheck.gstatic.com/generate_204")
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/curl"),args,timeout:13)
  guard result.code==0,result.output=="204" else{throw LinkError.failure("NO_UPSTREAM","实际HTTPS请求失败（\(result.code)）：\(result.output)")}
 }
 public static func waitForDefaultInterface(_ expected:String?,seconds:TimeInterval=15) async throws {
  let deadline=ProcessInfo.processInfo.systemUptime+seconds
  repeat {
   if try await defaultInterface()==expected {return}
   await Task.detached{try? await Task.sleep(nanoseconds:500_000_000)}.value
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("ROUTE_NOT_RESTORED","原系统出口尚未恢复；未擅自改写系统路由")
 }
 public static func defaultInterface() async throws -> String? {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/route"),["-n","get","default"],timeout:3)
  guard result.code==0 else{return nil}
  return result.output.split(separator:"\n").first(where:{$0.contains("interface:")})?.split(separator:":").last.map{String($0).trimmingCharacters(in:.whitespaces)}
 }
}
