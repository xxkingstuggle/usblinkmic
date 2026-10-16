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
 public static func linkActive(_ interface:String) async throws -> Bool {
  guard interface.range(of:#"^en[0-9]+$"#,options:.regularExpression) != nil else{return false}
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/ifconfig"),[interface],timeout:3)
  guard result.code==0 else{return false}
  return result.output.split(separator:"\n").contains {line in
   let fields=line.split(whereSeparator:{$0.isWhitespace})
   return fields.count==2 && fields[0]=="status:" && fields[1]=="active"
  }
 }
 public static func defaultInterface() async throws -> String? {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/route"),["-n","get","default"],timeout:3)
  guard result.code==0 else{return nil}
  return result.output.split(separator:"\n").first(where:{$0.contains("interface:")})?.split(separator:":").last.map{String($0).trimmingCharacters(in:.whitespaces)}
 }
}
