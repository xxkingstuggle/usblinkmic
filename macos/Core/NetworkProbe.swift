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
 // NCM must not depend on a single Google endpoint being reachable. Both probes
 // require TLS validation, a USB-bound IPv4 socket and the expected response.
 @MainActor static func verifyPhoneInternet(interface:String,trace:(String)->Void) async throws {
  let targets=[("https://captive.apple.com/hotspot-detect.html","Apple"),("https://connectivitycheck.gstatic.com/generate_204","Google")]
  var failures=[String]()
  for (url,label) in targets {
   let args=["--silent","--show-error","--ipv4","--interface",interface,"--noproxy","*","--proto","=https","--connect-timeout","5","--max-time","12","--max-filesize","4096","--write-out","\nLINKMIC_HTTP:%{http_code}",url]
   let result=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/curl"),args,timeout:13)
   let pieces=result.output.components(separatedBy:"\nLINKMIC_HTTP:")
   let body=pieces.first ?? "",code=pieces.count==2 ? pieces[1].trimmingCharacters(in:.whitespacesAndNewlines):"missing"
   let expected=label=="Google" ? code=="204" && body.isEmpty:code=="200" && body.range(of:#"(?i)<body>\s*Success\s*</body>"#,options:.regularExpression) != nil
   trace("target=\(label), interface=\(interface), curlExit=\(result.code), HTTP=\(code), expectedBody=\(expected)")
   if result.code==0,expected {return}
   // Do not log an unexpected HTML page; it can contain portal/user information.
   let error=result.code==0 ? "unexpected HTTP/body":String(body.prefix(600))
   failures.append("\(label): curl=\(result.code), HTTP=\(code), \(error)")
  }
  throw LinkError.failure("NO_UPSTREAM","USB地址已取得，但实际HTTPS出口请求未通过："+failures.joined(separator:"；"))
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
