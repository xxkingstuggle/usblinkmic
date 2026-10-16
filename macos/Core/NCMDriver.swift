import Foundation

/// USB mode changes are acknowledged by state after reconnection, not adb's exit code.
struct NCMDriver {
 let adb: ADB
 static func quote(_ value:String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'" }
 static func functions(_ value:String) -> Set<String> {Set(value.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:",").map(String.init))}
 static func isOwnedResult(_ path:String,session:String) -> Bool {
  UUID(uuidString:session) != nil && ["/data/local/tmp/usblinkmic-\(session)-start.json","/data/local/tmp/usblinkmic-\(session)-stop.json"].contains(path)
 }
 private func pause(respectCancellation:Bool) async throws {
  if respectCancellation {try await Task.sleep(nanoseconds:500_000_000)}
  else {await Task.detached {try? await Task.sleep(nanoseconds:500_000_000)}.value}
 }
 func waitForDevice(_ serial:String,seconds:TimeInterval=45,respectCancellation:Bool=true) async throws {
  let deadline=ProcessInfo.processInfo.systemUptime+seconds
  repeat {
   if respectCancellation {try Task.checkCancellation()}
   let result=try await ProcessRunner.run(adb.executable,["-s",serial,"get-state"],timeout:2,cancellable:false)
   if result.code==0,result.output.trimmingCharacters(in:.whitespacesAndNewlines)=="device" {return}
   // Cleanup must still reconnect when the initiating task was cancelled.
   try await pause(respectCancellation:respectCancellation)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("USB_RECONNECT_TIMEOUT","USB切换后未重新连接；请接回同一部手机后重试停止以恢复")
 }
 func setFunctions(_ value:String,serial:String,respectCancellation:Bool=true) async throws {
  guard !value.isEmpty,value.range(of:#"^[a-zA-Z0-9_,]+$"#,options:.regularExpression) != nil else{throw LinkError.failure("USB_STATE_UNKNOWN","USB功能值无效")}
  let result=try await ProcessRunner.run(adb.executable,["-s",serial,"shell","svc","usb","setFunctions",value],timeout:8,cancellable:false)
  if result.output.range(of:"SecurityException|permission denied|unknown function|invalid function|not supported",options:[.regularExpression,.caseInsensitive]) != nil {
   throw LinkError.failure("ROM_UNSUPPORTED",result.output)
  }
  // A nonzero/137/255 exit may be the expected USB gadget reset, including opId messages.
  try await waitForDevice(serial,respectCancellation:respectCancellation)
  let deadline=ProcessInfo.processInfo.systemUptime+15
  repeat {
   if respectCancellation {try Task.checkCancellation()}
   let current=try await adb.run(serial,["shell","getprop","sys.usb.config"],timeout:3)
   let actual=Self.functions(current),expected=Self.functions(value)
   if actual==expected || (expected==["ncm"] && actual.contains("ncm")) {return}
   try await pause(respectCancellation:respectCancellation)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("USB_FUNCTION_NOT_APPLIED","手机重连后USB功能仍未达到请求值；未把ADB断开误报为ROM不支持")
 }
 func waitForEthernet(_ serial:String) async throws {
  let deadline=ProcessInfo.processInfo.systemUptime+15
  repeat {
   try Task.checkCancellation()
   let dump=try await adb.run(serial,["shell","dumpsys","ethernet"],timeout:4)
   if dump.contains("usb0") {return}
   try await Task.sleep(nanoseconds:500_000_000)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("NCM_NOT_TRACKED","USB已切到NCM，但手机EthernetTracker未识别usb0；此ROM不具备所需共享路径")
 }
 func result(at path:String,serial:String,session:String,seconds:TimeInterval=45,respectCancellation:Bool=true) async throws -> [String:Any] {
  guard Self.isOwnedResult(path,session:session) else{throw LinkError.failure("NCM_OWNERSHIP","拒绝读取非本次操作结果")}
  let deadline=ProcessInfo.processInfo.systemUptime+seconds
  repeat {
   if respectCancellation {try Task.checkCancellation()}
   let read=try await ProcessRunner.run(adb.executable,["-s",serial,"shell","cat",path],timeout:3,cancellable:false)
   if read.code==0 {
    for line in read.output.split(separator:"\n").reversed() {
     if let json=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],json["session"] as? String==session {return json}
    }
   }
   try await pause(respectCancellation:respectCancellation)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("NCM_BRIDGE_TIMEOUT","等待手机共享结果超时；停止/重连后可恢复，未报告网络可用")
 }
 func launch(_ action:String,serial:String,session:String,resultPath:String) async throws {
  guard ["start","stop"].contains(action),Self.isOwnedResult(resultPath,session:session) else{throw LinkError.failure("NCM_COMMAND","共享操作参数无效")}
  let package=try await adb.run(serial,["shell","pm","path","com.zjx.usblinkmic"],timeout:4)
  guard let line=package.split(separator:"\n").first(where:{$0.hasPrefix("package:")}) else{throw LinkError.failure("NCM_APP_MISSING","手机配套App不存在")}
  let apk=String(line.dropFirst(8))
  guard apk.hasPrefix("/data/app/"),apk.hasSuffix(".apk") else{throw LinkError.failure("NCM_APK_PATH","手机APK路径异常")}
  let command="setsid env CLASSPATH=\(Self.quote(apk)) app_process /system/bin com.zjx.usblinkmic.platform.NcmShellCommand \(action) \(Self.quote(session)) >\(Self.quote(resultPath)) 2>&1 </dev/null &"
  let launched=try await ProcessRunner.run(adb.executable,["-s",serial,"shell",command],timeout:8,cancellable:false)
  guard launched.code==0 || launched.code==137 || launched.code==255 else{throw LinkError.failure("NCM_BRIDGE_LAUNCH",launched.output)}
 }
 func removeResult(_ path:String,serial:String,session:String) async throws {
  guard Self.isOwnedResult(path,session:session) else{throw LinkError.failure("NCM_OWNERSHIP","拒绝清理非本次操作文件")}
  _ = try await adb.run(serial,["shell","rm","-f",path],timeout:3)
 }
 static func requireSuccess(_ json:[String:Any],action:String) throws {
  guard json["action"] as? String==action,json["ok"] as? Bool==true,json["errorCode"] as? Int==0,(action=="start" ? ["started"]:["stopped","stopSubmitted"]).contains(json["callback"] as? String ?? "") else{
   throw LinkError.failure("NCM_TETHERING_FAILED","手机共享接口调用失败：\(json["error"] ?? json["errorCode"] ?? "无有效回执")")
  }
 }
}
