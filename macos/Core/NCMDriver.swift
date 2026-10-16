import Foundation

/// USB mode changes are acknowledged by the active framework state after reconnection.
@MainActor struct NCMDriver {
 let adb: ADB
 var trace: (String,String)->Void = {_,_ in}
 struct USBState {
  let framework:String?;let state:String?;let config:String?
  // sys.usb.config is an input property; it can lag the active gadget indefinitely.
  var active:String? {framework ?? state}
  var saved:String? {active ?? config}
  var summary:String {"getFunctions=\(framework ?? "unavailable"), sys.usb.state=\(state ?? "unavailable"), sys.usb.config=\(config ?? "unavailable")"}
 }
 static func quote(_ value:String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'" }
 static func functions(_ value:String) -> Set<String> {Set(value.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:",").map(String.init))}
 static func validFunctions(_ value:String)->Bool {!value.isEmpty && value.range(of:#"^[a-zA-Z0-9_,]+$"#,options:.regularExpression) != nil && !["null","unknown"].contains(value)}
 static func isOwnedResult(_ path:String,session:String) -> Bool {
  UUID(uuidString:session) != nil && ["/data/local/tmp/usblinkmic-\(session)-start.json","/data/local/tmp/usblinkmic-\(session)-stop.json"].contains(path)
 }
 private func pause(respectCancellation:Bool) async throws {
  if respectCancellation {try await Task.sleep(nanoseconds:500_000_000)}
  else {await Task.detached {try? await Task.sleep(nanoseconds:500_000_000)}.value}
 }
 func usbState(_ serial:String) async throws -> USBState {
  var values=[String?]()
  for (index,args) in [["svc","usb","getFunctions"],["getprop","sys.usb.state"],["getprop","sys.usb.config"]].enumerated() {
   let r=try await ProcessRunner.run(adb.executable,["-s",serial,"shell"]+args,timeout:3,cancellable:false)
   let value=r.output.trimmingCharacters(in:.whitespacesAndNewlines)
   // Only successful framework getFunctions has the empty FUNCTION_NONE meaning.
   // Empty properties and failed commands remain unavailable.
   values.append(r.code==0 && index==0 && value.isEmpty ? "none":(r.code==0 && Self.validFunctions(value) ? value:nil))
   if r.code != 0 || (!value.isEmpty && !Self.validFunctions(value)) {trace("usbStateRead","\(args.joined(separator:" ")) exit=\(r.code): \(r.output.prefix(800))")}
  }
  return USBState(framework:values[0],state:values[1],config:values[2])
 }
 func waitForDevice(_ serial:String,seconds:TimeInterval=45,respectCancellation:Bool=true) async throws {
  let deadline=ProcessInfo.processInfo.systemUptime+seconds
  var last=""
  repeat {
   if respectCancellation {try Task.checkCancellation()}
   let result=try await ProcessRunner.run(adb.executable,["-s",serial,"get-state"],timeout:2,cancellable:false)
   if result.code==0,result.output.trimmingCharacters(in:.whitespacesAndNewlines)=="device" {trace("usbReconnect","同一手机ADB已连接");return}
   let detail="get-state exit=\(result.code): \(result.output.trimmingCharacters(in:.whitespacesAndNewlines))"
   if detail != last {trace("usbReconnect",detail);last=detail}
   try await pause(respectCancellation:respectCancellation)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("USB_RECONNECT_TIMEOUT","USB切换后未重新连接；请接回同一部手机后重试停止以恢复")
 }
 func setFunctions(_ value:String,serial:String,respectCancellation:Bool=true) async throws {
  guard Self.validFunctions(value) else{throw LinkError.failure("USB_STATE_UNKNOWN","USB功能值无效")}
  let result=try await ProcessRunner.run(adb.executable,["-s",serial,"shell","svc","usb","setFunctions",value],timeout:8,cancellable:false)
  trace("usbSetFunctions","requested=\(value), exit=\(result.code), output=\(result.output.prefix(1200))")
  if result.output.range(of:"SecurityException|permission denied|unknown function|invalid function|not supported",options:[.regularExpression,.caseInsensitive]) != nil {
   throw LinkError.failure("ROM_UNSUPPORTED",result.output)
  }
  try await waitForDevice(serial,respectCancellation:respectCancellation)
  let deadline=ProcessInfo.processInfo.systemUptime+15
  var last=""
  repeat {
   if respectCancellation {try Task.checkCancellation()}
   let current=try await usbState(serial)
   if current.summary != last {trace("usbFunctions",current.summary);last=current.summary}
   let expected=Self.functions(value)
   if let active=current.active {
    let actual=Self.functions(active)
    if actual==expected || (expected==["ncm"] && actual.contains("ncm")) {return}
   }
   if expected==["ncm"] {
    do {
     if try await ethernetTracked(serial) {trace("usbFunctions","ROM功能读数未同步；EthernetTracker已实际跟踪usb0，继续共享确认");return}
    } catch {
     guard case LinkError.failure(let code,_) = error,["DEVICE_DISCONNECTED","DEVICE_OFFLINE","USB_UNAUTHORIZED"].contains(code) else{throw error}
     trace("usbReenumerating",error.localizedDescription)
     try await waitForDevice(serial,respectCancellation:respectCancellation)
     // The first get-state can precede a delayed gadget reset. Re-read after it.
     let reconnected=try await usbState(serial)
     if let active=reconnected.active,Self.functions(active).contains("ncm") {trace("usbFunctions",reconnected.summary);return}
     if try await ethernetTracked(serial) {trace("usbFunctions","重连后usb0已被实际跟踪");return}
    }
   }
   try await pause(respectCancellation:respectCancellation)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("USB_FUNCTION_NOT_APPLIED","未确认请求的USB功能；\(last)")
 }
 private func ethernetTracked(_ serial:String) async throws -> Bool {
  let dump=try await adb.run(serial,["shell","dumpsys","ethernet"],timeout:4)
  return dump.range(of:#"\busb0\b"#,options:.regularExpression) != nil
 }
 func waitForEthernet(_ serial:String) async throws {
  let deadline=ProcessInfo.processInfo.systemUptime+15
  repeat {
   try Task.checkCancellation()
   do {
    if try await ethernetTracked(serial) {trace("ethernetTracked","EthernetTracker包含usb0");return}
   }catch {
    guard case LinkError.failure(let code,_) = error,["DEVICE_DISCONNECTED","DEVICE_OFFLINE","USB_UNAUTHORIZED"].contains(code) else{throw error}
    trace("usbReenumerating",error.localizedDescription);try await waitForDevice(serial)
    if try await ethernetTracked(serial) {trace("ethernetTracked","重连后EthernetTracker包含usb0");return}
   }
   try await pause(respectCancellation:true)
  }while ProcessInfo.processInfo.systemUptime<deadline
  trace("ethernetTracked","15秒内EthernetTracker没有usb0")
  throw LinkError.failure("NCM_NOT_TRACKED","USB已切到NCM，但手机EthernetTracker未识别usb0；此ROM不具备所需共享路径")
 }
 private func helperCommand(_ action:String,serial:String,session:String) async throws -> String {
  guard ["start","stop","status"].contains(action),UUID(uuidString:session) != nil else{throw LinkError.failure("NCM_COMMAND","共享操作参数无效")}
  let package=try await adb.run(serial,["shell","pm","path","com.zjx.usblinkmic"],timeout:4)
  guard let line=package.split(separator:"\n").first(where:{$0.hasPrefix("package:")}) else{throw LinkError.failure("NCM_APP_MISSING","手机配套App不存在")}
  let apk=String(line.dropFirst(8))
  guard apk.hasPrefix("/data/app/"),apk.hasSuffix(".apk") else{throw LinkError.failure("NCM_APK_PATH","手机APK路径异常")}
  return "env CLASSPATH=\(Self.quote(apk)) app_process /system/bin com.zjx.usblinkmic.platform.NcmShellCommand \(action) \(Self.quote(session))"
 }
 private func receipt(_ text:String,session:String)->[String:Any]? {
  for line in text.split(separator:"\n").reversed() {
   if let json=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],json["session"] as? String==session {return json}
  }
  return nil
 }
 func tetheredInterfaces(serial:String,session:String) async throws -> [String] {
  let command=try await helperCommand("status",serial:serial,session:session)
  let result=try await ProcessRunner.run(adb.executable,["-s",serial,"shell",command],timeout:12,cancellable:false)
  trace("tetheringStatus","exit=\(result.code), \(result.output.prefix(2400))")
  guard let json=receipt(result.output,session:session),json["action"] as? String=="status",json["ok"] as? Bool==true,let interfaces=json["tethered"] as? [String] else{throw LinkError.failure("NCM_STATUS_FAILED","无法读取真实共享接口：\(result.output.prefix(1200))")}
  return interfaces
 }
 func waitForTethering(serial:String,session:String,active:Bool,respectCancellation:Bool=true) async throws {
  let deadline=ProcessInfo.processInfo.systemUptime+15
  repeat {
   if respectCancellation {try Task.checkCancellation()}
   let interfaces=try await tetheredInterfaces(serial:serial,session:session)
   if interfaces.contains("usb0")==active {return}
   try await pause(respectCancellation:respectCancellation)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure(active ? "NCM_NOT_TETHERED":"NCM_STILL_TETHERED",active ? "共享启动回调已返回，但usb0未进入实际共享列表":"停止已提交，但usb0仍在实际共享列表")
 }
 func result(at path:String,serial:String,session:String,seconds:TimeInterval=45,respectCancellation:Bool=true) async throws -> [String:Any] {
  guard Self.isOwnedResult(path,session:session) else{throw LinkError.failure("NCM_OWNERSHIP","拒绝读取非本次操作结果")}
  let deadline=ProcessInfo.processInfo.systemUptime+seconds
  var last=""
  repeat {
   if respectCancellation {try Task.checkCancellation()}
   let read=try await ProcessRunner.run(adb.executable,["-s",serial,"shell","cat",path],timeout:3,cancellable:false)
   if read.code==0,let json=receipt(read.output,session:session) {trace("tetheringReceipt",String(read.output.prefix(2400)));return json}
   let detail="exit=\(read.code), \(read.output.prefix(1200))"
   if detail != last {trace("tetheringReceiptPending",detail);last=detail}
   try await pause(respectCancellation:respectCancellation)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("NCM_BRIDGE_TIMEOUT","等待手机共享结果超时；最后输出：\(last)")
 }
 func launch(_ action:String,serial:String,session:String,resultPath:String) async throws {
  guard ["start","stop"].contains(action),Self.isOwnedResult(resultPath,session:session) else{throw LinkError.failure("NCM_COMMAND","共享操作参数无效")}
  let helper=try await helperCommand(action,serial:serial,session:session)
  let command="setsid \(helper) >\(Self.quote(resultPath)) 2>&1 </dev/null &"
  let launched=try await ProcessRunner.run(adb.executable,["-s",serial,"shell",command],timeout:8,cancellable:false)
  trace("tetheringLaunch","action=\(action), exit=\(launched.code), \(launched.output.prefix(1200))")
  guard launched.code==0 || launched.code==137 || launched.code==255 else{throw LinkError.failure("NCM_BRIDGE_LAUNCH",launched.output)}
 }
 func removeResult(_ path:String,serial:String,session:String) async throws {
  guard Self.isOwnedResult(path,session:session) else{throw LinkError.failure("NCM_OWNERSHIP","拒绝清理非本次操作文件")}
  _ = try await adb.run(serial,["shell","rm","-f",path],timeout:3)
 }
 static func requireSuccess(_ json:[String:Any],action:String) throws {
  // Android may report UNKNOWN_REQUEST when an earlier cleanup already stopped
  // this request. The caller still verifies usb0 has left the tethered list.
  if action=="stop",json["action"] as? String==action,json["errorCode"] as? Int==17 {return}
  guard json["action"] as? String==action,json["ok"] as? Bool==true,json["errorCode"] as? Int==0,(action=="start" ? ["started"]:["stopped","stopSubmitted"]).contains(json["callback"] as? String ?? "") else{
   throw LinkError.failure("NCM_TETHERING_FAILED","手机共享接口调用失败：\(json["error"] ?? json["errorCode"] ?? "无有效回执")")
  }
 }
}
