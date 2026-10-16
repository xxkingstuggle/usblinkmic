import Foundation

struct NCMNetworkService: Equatable {
 let name:String
 let device:String
 let hardware:String
 var phoneNamed:Bool {
  let value=(name+" "+hardware).lowercased()
  return ["ncm","android","xiaomi","redmi","pixel","samsung","huawei","honor","oppo","vivo","oneplus","手机"].contains{value.contains($0)}
 }
 var usbNamed:Bool {
  let value=(name+" "+hardware).lowercased()
  guard !["iphone","ipad","ipod"].contains(where:{hardware.lowercased().contains($0)}) else{return false}
  guard !["wi-fi","wifi","bluetooth","thunderbolt"].contains(where:{hardware.lowercased().contains($0)}) else{return false}
  return phoneNamed || (value.contains("usb") && !["wi-fi","wifi","bluetooth","thunderbolt"].contains{value.contains($0)})
 }
}
struct NCMServiceReceipt: Codable {
 let name:String
 let device:String
 let wasEnabled:Bool
}
/// Only enables an attributable USB service. Never edits service order, DHCP,
/// DNS, Wi-Fi or routes. The journal is saved by the caller before any mutation.
@MainActor struct NCMNetworkServices {
 var trace:(String,String)->Void = {_,_ in}
 private let executable=URL(fileURLWithPath:"/usr/sbin/networksetup")
 private func command(_ args:[String]) async throws -> String {
  let result=try await ProcessRunner.run(executable,args,timeout:6,cancellable:false)
  // networksetup sometimes returns exit 0 with a textual error.
  guard result.code==0,result.output.range(of:"Error:|not a recognized network service|You need administrator access",options:[.regularExpression,.caseInsensitive])==nil else{throw LinkError.failure("MAC_NETWORK_SERVICE","\(args.first ?? "networksetup") exit=\(result.code): \(result.output)")}
  return result.output
 }
 func detect() async throws {_ = try await command(["-detectnewhardware"])}
 func diagnostics(_ service:NCMNetworkService) async throws {
  let info=try await command(["-getinfo",service.name])
  let fields=info.split(separator:"\n").filter{line in ["DHCP Configuration","IP address:","Subnet mask:","Router:","IPv6:"].contains{line.hasPrefix($0)}}
  trace("macDHCP","service=\(service.name), device=\(service.device), \(fields.joined(separator:"; "))")
 }
 func list() async throws -> [NCMNetworkService] {
  let text=try await command(["-listnetworkserviceorder"])
  var name="";var services=[NCMNetworkService]()
  for line in text.split(separator:"\n").map({String($0).trimmingCharacters(in:.whitespaces)}) {
   if let range=line.range(of:#"^\((?:[0-9]+|\*)\)\s*"#,options:.regularExpression) {
    name=String(line[range.upperBound...]);if name.hasPrefix("*"){name.removeFirst();name=name.trimmingCharacters(in:.whitespaces)}
   }else if line.hasPrefix("(Hardware Port: "),let range=line.range(of:", Device: "),line.hasSuffix(")"),!name.isEmpty {
    let hardware=String(line[line.index(line.startIndex,offsetBy:"(Hardware Port: ".count)..<range.lowerBound])
    let device=String(line[range.upperBound...].dropLast())
    if device.range(of:#"^en[0-9]+$"#,options:.regularExpression) != nil {services.append(NCMNetworkService(name:name,device:device,hardware:hardware))}
   }
  }
  return services
 }
 func enabled(_ name:String) async throws -> Bool {
  let value=try await command(["-getnetworkserviceenabled",name]).trimmingCharacters(in:.whitespacesAndNewlines)
  guard ["Enabled","Disabled"].contains(value) else{throw LinkError.failure("MAC_SERVICE_STATE","无法读取USB网络服务原状态：\(value)")}
  return value=="Enabled"
 }
 func setEnabled(_ value:Bool,receipt:NCMServiceReceipt) async throws {
  let services=try await list()
  guard services.contains(where:{$0.name==receipt.name && $0.device==receipt.device}) else{throw LinkError.failure("MAC_SERVICE_OWNERSHIP_CHANGED","USB网络服务已改名或关联改变，未修改")}
  let current=try await enabled(receipt.name)
  if current != value {_ = try await command(["-setnetworkserviceenabled",receipt.name,value ? "on":"off"])}
  guard try await enabled(receipt.name)==value else{throw LinkError.failure("MAC_SERVICE_STATE","USB网络服务状态未达到请求值")}
  trace("macService", "service=\(receipt.name), device=\(receipt.device), enabled=\(value), original=\(receipt.wasEnabled)")
 }
 func restore(_ receipt:NCMServiceReceipt) async throws {
  guard !receipt.wasEnabled else{return}
  let services=try await list()
  // A disappeared service needs no restoration; a renamed/reassigned one is not ours.
  guard services.contains(where:{$0.name==receipt.name}) else{trace("macServiceRestore","原USB服务已消失，无需恢复");return}
  try await setEnabled(false,receipt:receipt)
 }
 /// IORegistry associates persistent enX interfaces with the selected phone's USB
 /// serial. No raw registry/serial/MAC data is logged or persisted.
 func phoneInterfaces(serial:String) async throws -> Set<String> {
  let r=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/sbin/ioreg"),["-a","-r","-c","IOUSBHostDevice"],timeout:6,cancellable:false)
  guard r.code==0,let data=r.output.data(using:.utf8),let tree=try? PropertyListSerialization.propertyList(from:data,format:nil) else{
   trace("usbAssociation","IORegistry关联不可读，exit=\(r.code), bytes=\(r.output.utf8.count)；继续检查独立USB服务证据")
   return []
  }
  var matches=Set<String>()
  func visit(_ node:Any,_ parentMatches:Bool) {
   if let nodes=node as? [Any] {for child in nodes {visit(child,parentMatches)};return}
   guard let item=node as? [String:Any] else{return}
   let ownSerial=["USB Serial Number","kUSBSerialNumberString","USBSerialNumber"].compactMap{item[$0] as? String}.contains(serial)
   let selected=parentMatches || ownSerial
   if selected {
    if let name=item["BSD Name"] as? String,name.range(of:#"^en[0-9]+$"#,options:.regularExpression) != nil {matches.insert(name)}
    if item["IOInterfaceNamePrefix"] as? String=="en",let unit=item["IOInterfaceUnit"] as? Int {matches.insert("en\(unit)")}
   }
   if let children=item["IORegistryEntryChildren"] {visit(children,selected)}
  }
  visit(tree,false)
  return matches
 }
 func select(from services:[NCMNetworkService],baseline:Set<String>,associated:Set<String>) throws -> NCMNetworkService? {
  let direct=services.filter{associated.contains($0.device)}
  if direct.count==1 {return direct[0]}
  if direct.count>1 {throw LinkError.failure("NCM_INTERFACE_AMBIGUOUS","同一手机关联多个Mac网络服务，未修改")}
  // Reused interfaces need positive phone identification, not a generic LAN name.
  let reused=services.filter{$0.phoneNamed && $0.usbNamed}
  if reused.count==1 {return reused[0]}
  if reused.count>1 {throw LinkError.failure("NCM_INTERFACE_AMBIGUOUS","存在多个手机网络服务，未修改")}
  // Include persistent services in the baseline, even if their BSD device is absent.
  let created=services.filter{!baseline.contains($0.device) && $0.usbNamed}
  if created.count==1 {return created[0]}
  if created.count>1 {throw LinkError.failure("NCM_INTERFACE_AMBIGUOUS","出现多个新USB网络服务，未修改")}
  return nil
 }
}
