import Foundation
import Combine
import AppKit
import CryptoKit
import Darwin
import Contracts
import Support

private struct OwnedSession: Codable {
 var id:String; var serial:String; var token:String; var controlForward:Int?; var controlTarget:Int?; var controlComponent:String?; var reverse:String?; var relayPID:Int32?; var relayExecutable:String?; var ncmServices:[NCMServiceReceipt]?; var ncmUSBChanged:Bool?; var ncmRequested:Bool?; var ncmBorrowed:Bool?; var ncmPendingStart:String?; var ncmResults:[String]?; var oldUSB:String?; var originalInterface:String?; var module:String
}
@MainActor public final class SessionController: ObservableObject, AppControlling {
 @Published public private(set) var snapshot=AppSnapshot()
 private let store:SettingsStore
 private let root:URL
 private let adb:ADB
 private let journal:URL
 private let diagnosticLog:DiagnosticLog
 private var owned:[Workspace:OwnedSession]=[:]
 private var jobs:[Workspace:Task<Void,Never>]=[:]
 private var jobIDs:[Workspace:String]=[:]
 private var stopping=Set<Workspace>()
 private var stopJobs:[Workspace:Task<Void,Never>]=[:]
 private var recoveryJob:Task<Void,Never>?
 private var ncmUSBChange:(id:String,task:Task<Void,Error>)?
 private var ncmServiceChange:(id:String,task:Task<Void,Error>)?
 private var ncmInterface:String?
 private let receiver=AudioReceiver()
 private let output=AudioOutput()
 private var relay:Process?
 private var audioWatchdog=AudioSessionWatchdog()
 private var failingAudioSessions=Set<String>()
 private var timer:Task<Void,Never>?
 private var deviceMonitor:Task<Void,Never>?
 private var ncmMonitor:Task<Void,Never>?
 private var booted=false
 private var recovering=true
 private var recoveryBlocked=false
 private var quitting=false
 private var onboardingURL:URL {journal.deletingLastPathComponent().appendingPathComponent("onboarding.json")}
 public init(resourceRoot:URL?=nil, stateDirectory:URL?=nil) {
  root=resourceRoot ?? Bundle.main.resourceURL ?? URL(fileURLWithPath:"/nonexistent")
  adb=ADB(executable:root.appendingPathComponent("platform-tools/adb"))
  let directory=stateDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("USBLinkMic-v4")
  store=SettingsStore(url:directory.appendingPathComponent("settings.json"));journal=directory.appendingPathComponent("owned-sessions.json")
  diagnosticLog=DiagnosticLog(url:directory.appendingPathComponent("diagnostics.log"))
  do {snapshot.settings=try store.load()} catch {snapshot.recoveryMessage="配置加载失败：\(error.localizedDescription)"}
  do {snapshot.logs=Array(try diagnosticLog.load().suffix(500))} catch {snapshot.recoveryMessage="历史日志读取失败：\(error.localizedDescription)"}
  snapshot.outputs=AudioOutput.devices()
  if let data=try? Data(contentsOf:onboardingURL),let flags=try? JSONDecoder().decode([String:Bool].self,from:data){snapshot.wizardSkipped=flags["skipped"] ?? false;snapshot.soundTestCompleted=flags["soundTest"] ?? false}
 }
 public func boot() {
  guard !booted else{return};booted=true
  recoveryJob=Task {await recover();recovering=false;recoveryJob=nil;await refresh()}
  timer=Task {while !Task.isCancelled {try? await Task.sleep(nanoseconds:1_000_000_000);await tick()}}
  deviceMonitor=Task {while !Task.isCancelled {try? await Task.sleep(nanoseconds:3_000_000_000);if !Task.isCancelled {await refresh()}}}
 }
 public func send(_ action:UserAction) {
  switch action {
  case .refresh:Task{await refresh()}
  case .selectDevice(let serial):snapshot.selectedDeviceID=serial
  case .start(let module):start(module)
  case .stop(let module):Task{await stop(module)}
  case .stopAll:Task{await stopAll()}
  case .saveSettings(let settings):
   guard !snapshot.isSavingSettings else{return}
   let errors=SettingsValidator.errors(settings)+SettingsValidator.outputErrors(settings,outputs:AudioOutput.devices())
   guard errors.isEmpty else {snapshot.settingsMessage=errors.joined(separator:"；");log("settings","invalid",snapshot.settingsMessage);return}
   snapshot.isSavingSettings=true;snapshot.settingsMessage="正在停止连接并保存设置"
   Task {
    defer{snapshot.isSavingSettings=false}
    await stopAll()
    guard owned.isEmpty else{snapshot.settingsMessage="停止未完成，设置未保存；请重试全部停止";log("settings","failed",snapshot.settingsMessage);return}
    do {try store.save(settings);snapshot.settings=settings;snapshot.settingsMessage="设置已保存，请点击开始重新连接";log("settings","saved",snapshot.settingsMessage)}
    catch{snapshot.settingsMessage="设置保存失败：\(error.localizedDescription)";log("settings","failed",snapshot.settingsMessage)}
   }
  case .setGain(let gain):guard gain.isFinite,(0...4).contains(gain) else{return};snapshot.settings.gain=gain;output.gain=Float(gain)
  case .setMuted(let muted):snapshot.settings.muted=muted;output.muted=muted
  case .skipWizard:snapshot.wizardSkipped=true;saveOnboarding()
  case .completeSoundTest:if snapshot.receivedFrames>0,snapshot.microphone.phase == .running {snapshot.soundTestCompleted=true;saveOnboarding()}
  case .clearLogs:do{try diagnosticLog.clear();snapshot.logs=[]}catch{log("logs","clearFailed",error.localizedDescription)}
  case .exportLogs:exportLogs()
  case .openDriverHelp:NSWorkspace.shared.open(URL(string:"https://existential.audio/blackhole/")!)
  case .openPhoneSettings:if let serial=snapshot.selectedDeviceID {Task{do{_ = try await adb.run(serial,["shell","am","start","-a","android.settings.APPLICATION_DETAILS_SETTINGS","-d","package:com.zjx.usblinkmic"])}catch{log("permission","failed",error.localizedDescription)}}}
  }
 }
 private func saveOnboarding(){do{try FileManager.default.createDirectory(at:onboardingURL.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(["skipped":snapshot.wizardSkipped,"soundTest":snapshot.soundTestCompleted]).write(to:onboardingURL,options:.atomic)}catch{log("wizard","saveFailed",error.localizedDescription)}}
 private func log(_ module:String,_ stage:String,_ text:String){var safe=text;for serial in Set(snapshot.devices.map{$0.id}+owned.values.map{$0.serial}+[snapshot.selectedDeviceID ?? ""]) where !serial.isEmpty {safe=safe.replacingOccurrences(of:serial,with:"serial=[REDACTED]")};for credential in Set(owned.values.map{$0.token}+[snapshot.settings.pairingCode]) where !credential.isEmpty {safe=safe.replacingOccurrences(of:credential,with:"[REDACTED]")};let entry=LogEntry(module:module,stage:stage,message:String(LogRedactor.redact(safe).prefix(8192)));snapshot.logs.append(entry);do{try diagnosticLog.append(entry)}catch{snapshot.recoveryMessage="诊断日志写入失败：\(error.localizedDescription)"};if snapshot.logs.count>500 {snapshot.logs.removeFirst(snapshot.logs.count-500)}}
 private func status(_ module:Workspace,_ phase:TaskPhase,_ stage:String,_ detail:String="",_ code:String?=nil) {
  var s=ModuleStatus();s.phase=phase;s.stage=stage;s.detail=detail;s.errorCode=code;s.taskID=owned[module]?.id
  switch module{case .microphone:snapshot.microphone=s;case .phoneInternet:snapshot.phoneInternet=s;case .macInternet:snapshot.macInternet=s;default:break}
  log(module.rawValue,stage,detail)
 }
 private func valid(_ module:Workspace,_ id:String)->Bool{owned[module]?.id==id && !stopping.contains(module) && !Task.isCancelled}
 private func saveJournal() throws {try FileManager.default.createDirectory(at:journal.deletingLastPathComponent(),withIntermediateDirectories:true);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:journal.deletingLastPathComponent().path);try JSONEncoder().encode(Array(owned.values)).write(to:journal,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)}
 private func recover() async {
  guard FileManager.default.fileExists(atPath:journal.path) else{return}
  do {
   let sessions=try JSONDecoder().decode([OwnedSession].self,from:Data(contentsOf:journal))
   var recovered=[Workspace:OwnedSession]()
   for session in sessions {
    guard let module=Workspace(rawValue:session.module),[Workspace.microphone,.phoneInternet,.macInternet].contains(module),recovered[module]==nil else{throw LinkError.failure("JOURNAL_INVALID","恢复记录包含未知或重复任务，保留原记录")}
    recovered[module]=session
   }
   owned=recovered
   var errors=[String]()
   for session in sessions {
    guard let module=Workspace(rawValue:session.module) else{continue}
    do {
     let warnings=try await cleanup(session);owned[module]=nil;try saveJournal();if !warnings.isEmpty {log(module.rawValue,"recoveryWarning",warnings.joined(separator:"；"))}
     log(module.rawValue,"recovered","上次会话资源已清理；未重新开始任务")
    }catch {
     owned[module]=session
     errors.append(error.localizedDescription)
     status(module,.failed,"上次资源恢复待重试，请点击全部停止",error.localizedDescription,"CLEANUP_INCOMPLETE")
    }
   }
   try saveJournal()
   if !sessions.isEmpty {snapshot.recoveryMessage=errors.isEmpty ? "上次会话资源已清理；未恢复录音":"上次资源清理未完成："+errors.joined(separator:"；")}
  }catch {
   recoveryBlocked=true;snapshot.recoveryMessage="恢复记录读取或保存失败：\(error.localizedDescription)"
   log("recovery","failed",snapshot.recoveryMessage)
  }
 }
 private func refresh() async {
  snapshot.outputs=AudioOutput.devices()
  do {
   let text=try await adb.run(nil,["devices","-l"])
   snapshot.devices=ADB.devices(text).map{Device(id:$0.0,name:$0.0,state:$0.1=="device" ? .online:($0.1=="unauthorized" ? .unauthorized:.offline))}
   if snapshot.selectedDeviceID==nil,snapshot.devices.count==1 {snapshot.selectedDeviceID=snapshot.devices.first?.id}
  }catch{log("devices","failed",error.localizedDescription)}
 }
 private func start(_ module:Workspace) {
  guard [.microphone,.phoneInternet,.macInternet].contains(module),jobs[module]==nil,owned[module]==nil,!stopping.contains(module),!snapshot.isSavingSettings,!recovering,!recoveryBlocked,!quitting else{return}
  let jobID=UUID().uuidString;jobIDs[module]=jobID
  jobs[module]=Task{await execute(module);if jobIDs[module]==jobID {jobs[module]=nil;jobIDs[module]=nil}}
 }
 private func execute(_ module:Workspace) async {
  let id=UUID().uuidString
  var settings=snapshot.settings
  let token=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
  if module == .microphone,settings.transport == .wifi {if settings.pairingCode.isEmpty {settings.pairingCode=token;snapshot.settings.pairingCode=token}}
  else {settings.pairingCode=token}
  let serial=snapshot.selectedDeviceID ?? ""
  if module == .microphone {
   audioWatchdog.begin(id);snapshot.receivedFrames=0;snapshot.effectiveAudio=nil
   snapshot.level=0;snapshot.waveform=[];snapshot.audioState = .disconnected
  }
  owned[module]=OwnedSession(id:id,serial:serial,token:settings.pairingCode,module:module.rawValue)
  do {
   try saveJournal();status(module,.checking,"检查前置条件")
   let errors=SettingsValidator.errors(settings);guard errors.isEmpty else{throw LinkError.failure("INVALID_SETTINGS",errors.joined(separator:"；"))}
   if module != .microphone || settings.transport == .usb {
    guard !serial.isEmpty else{throw LinkError.failure("DEVICE_REQUIRED","连接USB手机并选择目标")}
    let devices=ADB.devices(try await adb.run(nil,["devices"]))
    guard let device=devices.first(where:{$0.0==serial}) else{throw LinkError.failure("DEVICE_DISCONNECTED","所选手机未连接")}
    guard device.1=="device" else{throw LinkError.failure(device.1=="unauthorized" ? "USB_UNAUTHORIZED":"DEVICE_OFFLINE","请在所选手机确认USB调试授权并重试")}
    try await prepareCompanion(module,id,serial)
   }
   guard valid(module,id) else{return}
   if module == .microphone {try await startAudio(id,serial,settings)}
   else if module == .phoneInternet {await stop(.macInternet);guard owned[.macInternet]==nil else{throw LinkError.failure("DIRECTION_CLEANUP_PENDING","反向供网资源未恢复；先重试停止")};try await startNCM(id,serial,settings)}
   else {await stop(.phoneInternet);guard owned[.phoneInternet]==nil else{throw LinkError.failure("DIRECTION_CLEANUP_PENDING","手机供网资源未恢复；先重试停止")};try await startReverse(id,serial,settings)}
  }catch {
   guard owned[module]?.id==id,!Task.isCancelled else{return}
   let message=error.localizedDescription
   let code:String
   if case LinkError.failure(let value,_) = error {code=value}else{code="TASK_FAILED"}
   log(module.rawValue,"operationFailed",message)
   await stop(module)
   // Retained ownership means cleanup failed. Do not replace that actionable
   // recovery status with the earlier operation error or pretend the task stopped.
   if owned[module]?.id==id {return}
   if module == .microphone {snapshot.audioState = .failed}
   else if ["ROM_UNSUPPORTED","NCM_NOT_TRACKED"].contains(code) {snapshot.networkState = .unsupported}
   else if code=="NO_UPSTREAM" {snapshot.networkState = .noInternet}
   else{snapshot.networkState = .failed}
   status(module,.failed,"操作失败",message,code)
  }
 }
 private func prepareCompanion(_ module:Workspace,_ id:String,_ serial:String) async throws {
  let exists=try await adb.run(serial,["shell","pm","list","packages","com.zjx.usblinkmic"])
  guard valid(module,id) else{throw CancellationError()}
  let installed=exists.split(separator:"\n").contains("package:com.zjx.usblinkmic")
  var compatible=false
  if installed {
   let capability=try await adb.run(serial,["shell","content","call","--uri","content://com.zjx.usblinkmic.capabilities","--method","capabilities"])
   compatible=Self.compatibleCompanion(capability)
  }
  if !compatible {
   let apk=root.appendingPathComponent("companion.apk");let checksum=root.appendingPathComponent("companion.sha256")
   guard FileManager.default.fileExists(atPath:apk.path),FileManager.default.fileExists(atPath:checksum.path) else{throw LinkError.failure("APK_MISSING","安装包内缺少配套APK或指纹；重新获取完整发行包")}
   let expected=try String(contentsOf:checksum,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
   let actual=SHA256.hash(data:try Data(contentsOf:apk)).map{String(format:"%02x",$0)}.joined()
   guard actual==expected else{throw LinkError.failure("APK_HASH_MISMATCH","配套APK校验失败，未安装")}
   status(module,.preparing,"安装配套App","如手机要求确认安装，请在手机操作；不会自动卸载已有App")
   _ = try await adb.run(serial,["install","-r",apk.path],timeout:180,cancellable:true)
   guard valid(module,id) else{throw CancellationError()}
   let installed=try await adb.run(serial,["shell","pm","list","packages","com.zjx.usblinkmic"])
   guard installed.contains("package:com.zjx.usblinkmic") else{throw LinkError.failure("INSTALL_NOT_CONFIRMED","未能复查配套App安装")}
  }
  let capability=try await adb.run(serial,["shell","content","call","--uri","content://com.zjx.usblinkmic.capabilities","--method","capabilities"])
  guard Self.compatibleCompanion(capability) else{throw LinkError.failure("APP_INCOMPATIBLE","配套App未报告所需协议与运行时能力；未强行降级或卸载数据")}

 }
 private static func compatibleCompanion(_ text:String) -> Bool {
  guard text.range(of:#"protocol=4(?:[,}\s])"#,options:.regularExpression) != nil,
        let range=text.range(of:#"runtimeRevision=[0-9]+"#,options:.regularExpression),
        let revision=Int(text[range].split(separator:"=").last ?? "") else{return false}
  return revision>=Capabilities.runtimeRevision && text.contains("controlComponent=\(Capabilities.androidControlComponent)") && text.range(of:#"controlRevision=1(?:[,}\s])"#,options:.regularExpression) != nil
 }
 private func launchPhone(_ module:Workspace,_ id:String,_ serial:String,_ settings:Settings,_ mode:String) async throws {
  let forward=try await adb.run(serial,["forward","tcp:0","tcp:\(settings.controlPort)"])
  guard let port=Int(forward) else{throw LinkError.failure("CONTROL_FORWARD","无法建立本会话控制通道")}
  guard valid(module,id) else{_ = try await adb.run(serial,["forward","--remove","tcp:\(port)"],timeout:3);throw CancellationError()}
  owned[module]?.controlForward=port;owned[module]?.controlTarget=settings.controlPort;owned[module]?.controlComponent=Capabilities.androidControlComponent;try saveJournal()
  let audio=settings.audio
  // NEW_TASK|MULTIPLE_TASK executes the protected transient entry every time.
  // Extras alone do not distinguish Android task identities.
  let args=["shell","am","start","-f","0x18000000","-n",Capabilities.androidControlComponent,"--es","mode",mode,"--es","session",id,"--es","token",settings.pairingCode,"--ei","rate",String(audio.sampleRate),"--ei","channels",String(audio.channels),"--es","format",audio.format.rawValue,"--es","source",audio.source.rawValue,"--ei","port",String(settings.audioPort),"--ei","controlPort",String(settings.controlPort),"--es","dns",settings.dns,"--es","routes",settings.routes]
  let launch=try await adb.run(serial,args)
  log(module.rawValue,"phoneLaunch",launch)
  guard launch.range(of:#"Error:|Error type|SecurityException|Permission Denial|Exception occurred"#,options:[.regularExpression,.caseInsensitive])==nil else{throw LinkError.failure("CONTROL_LAUNCH_REJECTED",launch)}
  status(module,.connecting,"正在启动手机会话","已从Mac发起；仅缺少系统录音或VPN权限时需要手机处理")
  // am start completes before onNewIntent registers the new request. Wait for the
  // authenticated session, without treating the previous control server as a protocol mismatch.
  let deadline=ProcessInfo.processInfo.systemUptime+8
  while valid(module,id) {
   do{_ = try await poll(module,id);return}
   catch {
    guard ProcessInfo.processInfo.systemUptime<deadline else{throw error}
    guard case LinkError.failure(let code,_) = error,["CONTROL_SESSION_PENDING","CONTROL_CONNECT","CONTROL_SEND","CONTROL_TIMEOUT"].contains(code) else{throw error}
    log(module.rawValue,"controlRegistrationPending","等待本次会话登记：\(code)")
   }
   try await Task.sleep(nanoseconds:300_000_000)
  }
  throw CancellationError()
 }
 private func poll(_ module:Workspace,_ id:String) async throws -> [String:Any] {
  guard let session=owned[module],session.id==id,let port=session.controlForward else{throw CancellationError()}
  let response=try await ControlClient.request(port:port,body:["command":"status","session":id,"token":session.token])
  guard valid(module,id) else{throw CancellationError()}
  if response["error"] as? String=="AUTH_REQUIRED" {throw LinkError.failure("CONTROL_SESSION_PENDING","手机尚未登记本次会话，请等待应用处理启动请求")}
  guard response["protocol"] as? Int == 4,response["session"] as? String == id else{throw LinkError.failure("PROTOCOL_MISMATCH","手机会话身份或协议不一致")}
  if let p=response["microphonePermission"] as? String{snapshot.microphonePermission=PermissionState(rawValue:p) ?? .notRequested}
  if let p=response["notificationPermission"] as? String{snapshot.notificationPermission=PermissionState(rawValue:p) ?? .notRequested}
  if let p=response["vpnPermission"] as? String{snapshot.vpnPermission=PermissionState(rawValue:p) ?? .notRequested}
  let waiting=(module == .microphone && response["microphonePermission"] as? String=="waiting") || (module == .macInternet && response["vpnPermission"] as? String=="waiting")
  let current=module == .microphone ? snapshot.microphone:(module == .macInternet ? snapshot.macInternet:snapshot.phoneInternet)
  if ![TaskPhase.running,.stopping,.failed].contains(current.phase) {
   if waiting,current.stage != "等待Android系统权限" {status(module,.waitingUser,"等待Android系统权限","系统录音或VPN权限尚未授予；无需应用内重复确认")}
   else if !waiting,current.stage == "等待Android系统权限" {status(module,.connecting,"系统权限已处理，继续启动")}
  }
  if let error=response["error"] as? String,!error.isEmpty{throw LinkError.failure("PHONE_ERROR",error)}
  return response
 }
 private func startAudio(_ id:String,_ serial:String,_ settings:Settings) async throws {
  let outputErrors=SettingsValidator.outputErrors(settings,outputs:AudioOutput.devices())
  guard outputErrors.isEmpty else{throw LinkError.failure("DRIVER_REQUIRED",outputErrors.joined(separator:"；"))}
  try output.start(settings);snapshot.effectiveAudio=settings.audio
  log("audio","outputStarted","purpose=\(settings.purpose.rawValue), output=\(settings.outputUID), session=\(id)")
  try receiver.start(settings:settings,session:settings.transport == .usb ? id:"wifi",onFrame:{[weak self] data in Task{@MainActor in
   guard let self=self,self.valid(.microphone,id) else{return}
   do{let (level,trend)=try self.output.consume(data,parameters:settings.audio);self.snapshot.level=level;self.snapshot.waveform=trend;self.snapshot.receivedFrames+=1;self.snapshot.audioState = .streaming;self.audioWatchdog.frame(id,now:ProcessInfo.processInfo.systemUptime);if self.snapshot.microphone.phase != .running {self.status(.microphone,.running,"有效音频传输","实际PCM帧已到达；静音帧也计为传输")}}
   catch{await self.failAudio(id,error.localizedDescription)}
  }},onError:{[weak self] message in Task{@MainActor in await self?.failAudio(id,message)}})
  snapshot.audioState = .handshake
  if settings.transport == .wifi {status(.microphone,.connecting,"等待Wi-Fi发送端","手机填写本机地址、端口和配对码；session固定为wifi");return}
  let reverse="tcp:\(settings.audioPort)"
  _ = try await adb.run(serial,["reverse","--no-rebind",reverse,reverse]);guard valid(.microphone,id) else{_ = try await adb.run(serial,["reverse","--remove",reverse],timeout:3);throw CancellationError()};owned[.microphone]?.reverse=reverse;try saveJournal()
  try await launchPhone(.microphone,id,serial,settings,"audio")
  var failures=0
  while valid(.microphone,id) {
   do{
    let state=try await poll(.microphone,id);failures=0
    if state["recording"] as? Bool == true {audioWatchdog.recording(id,now:ProcessInfo.processInfo.systemUptime);if snapshot.receivedFrames==0 {snapshot.audioState = .waitingFrame;status(.microphone,.connecting,"等待首包")};return}
    if state["cancelled"] as? Bool == true {throw LinkError.failure("USER_CANCELLED","手机已取消本次操作")}
   }catch{failures+=1;if failures>=3 {throw error}}
   try await Task.sleep(nanoseconds:1_000_000_000)
  }
 }
 private func failAudio(_ id:String,_ message:String) async {
  guard valid(.microphone,id),let session=owned[.microphone],!failingAudioSessions.contains(id) else{return}
  failingAudioSessions.insert(id);defer{failingAudioSessions.remove(id)}
  log("audio","failure","session=\(id), frames=\(snapshot.receivedFrames), reason=\(message)")
  if let port=session.controlForward,let response=try? await ControlClient.request(port:port,body:["command":"status","session":id,"token":session.token]),response["cancelled"] as? Bool == true {
   guard valid(.microphone,id) else{return}
   await stop(.microphone)
   if owned[.microphone]==nil {status(.microphone,.stopped,"手机已停止录音")}
   return
  }
  guard valid(.microphone,id) else{return}
  await stop(.microphone);snapshot.audioState = .failed
  if owned[.microphone]==nil {status(.microphone,.failed,"音频失败",message,"AUDIO_FAILED")}
 }
 private func startReverse(_ id:String,_ serial:String,_ settings:Settings) async throws {
  snapshot.networkState = .preparing
  guard valid(.macInternet,id) else{throw CancellationError()}
  let java=root.appendingPathComponent("runtime/bin/java");let jar=root.appendingPathComponent("relay.jar")
  guard FileManager.default.isExecutableFile(atPath:java.path),FileManager.default.fileExists(atPath:jar.path) else{throw LinkError.failure("RELAY_MISSING","发行包缺少内置转发运行时")}
  let p=Process();p.executableURL=java;p.arguments=["-DUSBLinkMic.session=\(id)","-jar",jar.path,"relay","-p","48128"];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
  try p.run();relay=p;owned[.macInternet]?.relayPID=p.processIdentifier;owned[.macInternet]?.relayExecutable=java.path;try saveJournal()
  p.terminationHandler={ [weak self] _ in Task{@MainActor in guard let self=self,self.valid(.macInternet,id) else{return};await self.stop(.macInternet);self.status(.macInternet,.failed,"转发进程已退出","检查日志并重新启动","RELAY_EXITED")} }
  let reverse="localabstract:usblinkmic-v4"
  _ = try await adb.run(serial,["reverse","--no-rebind",reverse,"tcp:48128"]);guard valid(.macInternet,id) else{_ = try await adb.run(serial,["reverse","--remove",reverse],timeout:3);throw CancellationError()};owned[.macInternet]?.reverse=reverse;try saveJournal()
  try await launchPhone(.macInternet,id,serial,settings,"vpn")
  var failures=0
  while valid(.macInternet,id) {
   do {let s=try await poll(.macInternet,id);failures=0
    if s["cancelled"] as? Bool == true {throw LinkError.failure("VPN_DENIED","手机取消了VPN授权")}
    if s["network"] as? String == "connected" {snapshot.networkState = .available;status(.macInternet,.running,"已连接","手机VPN接口与USB转发通道已就绪");return}
   } catch {failures+=1;if failures>=3 {throw error}}
   try await Task.sleep(nanoseconds:1_000_000_000)
  }
 }
 private func ncmDriver() -> NCMDriver {NCMDriver(adb:adb,trace:{[weak self] stage,text in self?.log("phoneInternet",stage,text)})}
 private func ncmServices() -> NCMNetworkServices {NCMNetworkServices(trace:{[weak self] stage,text in self?.log("phoneInternet",stage,text)})}
 private func enableNCMService(_ service:NCMNetworkService,id:String) async throws {
  let manager=ncmServices()
  let enabled=try await manager.enabled(service.name)
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  if !(owned[.phoneInternet]?.ncmServices ?? []).contains(where:{$0.name==service.name && $0.device==service.device}) {
   var receipts=owned[.phoneInternet]?.ncmServices ?? []
   receipts.append(NCMServiceReceipt(name:service.name,device:service.device,wasEnabled:enabled))
   owned[.phoneInternet]?.ncmServices=receipts
   try saveJournal()
   log("phoneInternet","macServiceBaseline","service=\(service.name), device=\(service.device), enabledBefore=\(enabled)")
  }
  guard let receipt=owned[.phoneInternet]?.ncmServices?.first(where:{$0.name==service.name && $0.device==service.device}) else{throw CancellationError()}
  if !enabled {
   let task=Task {try await manager.setEnabled(true,receipt:receipt)}
   ncmServiceChange=(id,task)
   do{try await task.value}catch{if ncmServiceChange?.id==id {ncmServiceChange=nil};throw error}
   if ncmServiceChange?.id==id {ncmServiceChange=nil}
  }
  guard valid(.phoneInternet,id) else{throw CancellationError()}
 }
 private func startNCM(_ id:String,_ serial:String,_ settings:Settings) async throws {
  snapshot.networkState = .preparing
  status(.phoneInternet,.preparing,"检查手机NCM能力","检查USB实际功能、真实共享接口及Mac USB服务；不修改其他网络服务或服务顺序")
  let allDevices=ADB.devices(try await adb.run(nil,["devices"]))
  guard allDevices.filter({$0.1=="device"}).count==1 else{throw LinkError.failure("NCM_DEVICE_AMBIGUOUS","NCM硬件接口无法可靠关联多台USB手机；本次请仅连接所选手机")}
  let driver=ncmDriver(),services=ncmServices()
  let usb=try await driver.usbState(serial)
  log("phoneInternet","usbBaseline",usb.summary)
  guard let functions=usb.active else{throw LinkError.failure("USB_STATE_UNKNOWN","无法读取原USB实际功能，未切换；\(usb.summary)")}
  let sdk=try await adb.run(serial,["shell","getprop","ro.build.version.sdk"],timeout:3)
  guard (Int(sdk) ?? 0)>=30 else{throw LinkError.failure("ROM_UNSUPPORTED","此ADB网络共享路径需要Android11及以上；麦克风仍可独立使用")}
  let before=try await NetworkProbe.interfaceNames()
  let baselineServices=try await services.list()
  let knownDevices=before.union(baselineServices.map{ $0.device })
  log("phoneInternet","macBaseline","interfaces=\(before.sorted()); services=\(baselineServices.map{"\($0.name):\($0.device) [\($0.hardware)]"})")
  owned[.phoneInternet]?.originalInterface=try await NetworkProbe.defaultInterface()
  try await launchPhone(.phoneInternet,id,serial,settings,"ncm")
  while valid(.phoneInternet,id) {
   let state=try await poll(.phoneInternet,id)
   if state["cancelled"] as? Bool == true {throw LinkError.failure("USER_CANCELLED","手机取消网络共享")}
   if state["accepted"] as? Bool == true {break}
   try await Task.sleep(nanoseconds:500_000_000)
  }
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  let existing=try await driver.tetheredInterfaces(serial:serial,session:id)
  let sharedUSB=existing.filter{$0.range(of:#"^(usb|eth)[0-9]+$"#,options:.regularExpression) != nil}
  guard sharedUSB.allSatisfy({$0=="usb0"}) else{throw LinkError.failure("USB_SHARING_ALREADY_OWNED","存在无法关联本手机的以太网共享，未修改：\(sharedUSB)")}
  let borrowedSharing=sharedUSB.contains("usb0")
  owned[.phoneInternet]?.ncmBorrowed=borrowedSharing;try saveJournal()
  if borrowedSharing {log("phoneInternet","existingSharingBorrowed","保留系统已开启的usb0共享；仅使用本手机USB出口，不重新申请或停止原共享")}
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  let alreadyNCM=NCMDriver.functions(functions).contains("ncm")
  if !alreadyNCM,owned[.microphone] != nil,snapshot.settings.transport == .usb {
   await stop(.microphone)
   guard owned[.microphone]==nil else{throw LinkError.failure("AUDIO_CLEANUP_PENDING","USB重枚举前请先完成音频停止")}
   log("audio","usbReenumeration","USB共享切换需要重新识别；网络准备后可重新开始手机麦克风")
  }
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  owned[.phoneInternet]?.oldUSB=functions;try saveJournal()
  let associatedBefore=try await services.phoneInterfaces(serial:serial)
  if let service=try services.select(from:baselineServices,baseline:knownDevices,associated:associatedBefore) {
   try await enableNCMService(service,id:id)
  }
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  if !alreadyNCM {
   owned[.phoneInternet]?.ncmUSBChanged=true;try saveJournal()
   status(.phoneInternet,.preparing,"切换USB到NCM","USB会短暂断开；按实际USB功能及usb0跟踪确认，不以sys.usb.config单项判断")
   let task=Task {try await driver.setFunctions("ncm",serial:serial)}
   ncmUSBChange=(id,task)
   do{try await task.value}catch{if ncmUSBChange?.id==id {ncmUSBChange=nil};throw error}
   if ncmUSBChange?.id==id {ncmUSBChange=nil}
  }else{log("phoneInternet","usbFunctions",borrowedSharing ? "USB已处于NCM；保留原共享并继续确认USB连接":"USB已处于NCM且未共享；继续启动共享，不把NCM模式误当作已供网")}
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  try await driver.waitForEthernet(serial)
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  guard let port=owned[.phoneInternet]?.controlForward else{throw LinkError.failure("CONTROL_FORWARD","缺少本次控制通道回执")}
  let mappings=try await adb.run(nil,["forward","--list"],timeout:3)
  if !ADB.ownsMapping(mappings,serial:serial,local:"tcp:\(port)",remote:"tcp:\(settings.controlPort)") {
   guard !mappings.split(separator:"\n").contains(where:{$0.split(whereSeparator:{$0.isWhitespace}).dropFirst().first==Substring("tcp:\(port)")}) else{throw LinkError.failure("OWNERSHIP_CHANGED","原控制端口已被其他会话使用，未覆盖")}
   _ = try await adb.run(serial,["forward","--no-rebind","tcp:\(port)","tcp:\(settings.controlPort)"])
   log("phoneInternet","controlRestored","USB重枚举后的本次控制通道已恢复")
  }
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  if !borrowedSharing {
   let startPath="/data/local/tmp/usblinkmic-\(id)-start.json",stopPath="/data/local/tmp/usblinkmic-\(id)-stop.json"
   owned[.phoneInternet]?.ncmRequested=true;owned[.phoneInternet]?.ncmPendingStart=startPath;owned[.phoneInternet]?.ncmResults=[startPath,stopPath];try saveJournal()
   status(.phoneInternet,.preparing,"启动手机以太网共享","等待TetheringManager启动回调及usb0实际进入共享列表")
   try await driver.launch("start",serial:serial,session:id,resultPath:startPath)
   let receipt=try await driver.result(at:startPath,serial:serial,session:id)
   guard valid(.phoneInternet,id) else{throw CancellationError()}
   owned[.phoneInternet]?.ncmPendingStart=nil;try saveJournal()
   try NCMDriver.requireSuccess(receipt,action:"start")
   try await driver.removeResult(startPath,serial:serial,session:id)
  } else {status(.phoneInternet,.preparing,"使用已开启的USB共享","停止仅恢复本次USB模式及Mac服务改动，保留原有共享")}
  try await driver.waitForTethering(serial:serial,session:id,active:true)
  guard valid(.phoneInternet,id) else{throw CancellationError()}
  let addressDeadline=ProcessInfo.processInfo.systemUptime+45
  var lastDiscovery="",lastDetectionError=""
  status(.phoneInternet,.connecting,"等待USB网卡DHCP地址","usb0已实际共享；识别新建或复用的USB网卡，恢复被关闭的本手机网络服务")
  while valid(.phoneInternet,id) {
   do{try await services.detect()}catch{let text=error.localizedDescription;if text != lastDetectionError {log("phoneInternet","hardwareDetection",text);lastDetectionError=text}}
   let mapping=try await services.list(),interfaces=try await NetworkProbe.interfaces()
   let associated=try await services.phoneInterfaces(serial:serial)
   let selected=try services.select(from:mapping,baseline:knownDevices,associated:associated)
   let discovery="phoneInterfaces=\(associated.sorted()), services=\(mapping.map{"\($0.name):\($0.device) [\($0.hardware)]"}), IPv4=\(interfaces.map{"\($0.name)=\($0.address)"}), selected=\(selected?.device ?? "none")"
   if discovery != lastDiscovery {log("phoneInternet","macDiscovery",discovery);lastDiscovery=discovery}
   if let service=selected {try await enableNCMService(service,id:id)}
   guard valid(.phoneInternet,id) else{throw CancellationError()}
   guard let service=selected,let candidate=interfaces.first(where:{$0.name==service.device}),try await NetworkProbe.linkActive(service.device) else{
    if let service=selected,ProcessInfo.processInfo.systemUptime>addressDeadline {try await services.diagnostics(service)}
    if ProcessInfo.processInfo.systemUptime>addressDeadline {throw LinkError.failure(selected==nil ? "NCM_INTERFACE_NOT_FOUND":"NCM_DHCP_TIMEOUT",selected==nil ? "未能可靠关联本手机USB网络服务；日志已记录服务与接口候选":"手机usb0已共享，但Mac USB服务未取得DHCP地址；日志已记录服务与接口状态")}
    try await Task.sleep(nanoseconds:2_000_000_000);continue
   }
   ncmInterface=candidate.name;snapshot.networkState = .available
   try await services.diagnostics(service)
   let defaultRoute=try await NetworkProbe.defaultInterface()
   status(.phoneInternet,.running,"已连接","USB共享接口=\(candidate.name)，链路与地址已就绪；系统默认出口=\(defaultRoute ?? "none")")
   if let session=owned[.phoneInternet],let port=session.controlForward {
    do{_ = try await ControlClient.request(port:port,body:["command":"ncmState","session":id,"token":session.token,"network":"connected"])}
    catch{log("phoneInternet","phoneStateDelivery",error.localizedDescription)}
   }
   ncmMonitor=Task { [weak self] in
    guard let self=self else{return}
    var linkWasReady=true
    while self.valid(.phoneInternet,id) {
     do {
      try await Task.sleep(nanoseconds:2_000_000_000)
      guard self.valid(.phoneInternet,id) else{return}
      let addressed=try await NetworkProbe.interfaces().contains(where:{$0.name==candidate.name})
      let active=try await NetworkProbe.linkActive(candidate.name)
      guard self.valid(.phoneInternet,id) else{return}
      let ready=addressed && active
      if ready != linkWasReady {
       self.snapshot.networkState=ready ? .available:.preparing
       self.status(.phoneInternet,ready ? .running:.connecting,ready ? "已连接":"USB连接暂时中断",ready ? "USB链路与地址已恢复":"任务与恢复记录保留；等待链路恢复，或点击停止")
       linkWasReady=ready
      }
     } catch is CancellationError {return}
     catch {
      guard self.valid(.phoneInternet,id) else{return}
      self.snapshot.networkState = .preparing
      if linkWasReady {self.status(.phoneInternet,.connecting,"正在读取USB状态",error.localizedDescription);linkWasReady=false}
     }
    }
   }
   return
  }
 }
 private func tick() async {
  let outputs=AudioOutput.devices();snapshot.outputs=outputs
  if owned[.microphone] != nil,snapshot.settings.outputUID != "default",!outputs.contains(where:{$0.id==snapshot.settings.outputUID}),let id=owned[.microphone]?.id {await failAudio(id,"OUTPUT_REMOVED: 指定输出离线，已停止，避免自动外放")}
  if let id=owned[.microphone]?.id {
   switch audioWatchdog.failure(id,now:ProcessInfo.processInfo.systemUptime) {
   case .interrupted:await failAudio(id,"INPUT_INTERRUPTED: 超过3秒没有有效帧")
   case .firstFrame:await failAudio(id,"FIRST_FRAME_TIMEOUT: 获准开始采音后15秒未收到帧")
   case nil:break
   }
  }
  if let s=owned[.macInternet],valid(.macInternet,s.id),snapshot.macInternet.phase == .running {
   do {
    let state=try await poll(.macInternet,s.id)
    if state["cancelled"] as? Bool == true {await stop(.macInternet);if owned[.macInternet]==nil {status(.macInternet,.stopped,"手机已停止VPN")};return}
    if state["network"] as? String != "connected" {throw LinkError.failure("NETWORK_LOST","手机VPN或USB转发通道已断开")}
   } catch {
    guard valid(.macInternet,s.id) else{return}
    await stop(.macInternet)
    if owned[.macInternet]==nil {status(.macInternet,.failed,"网络已中断",error.localizedDescription)}
   }
  }
 }
 private func cleanup(_ s:OwnedSession) async throws -> [String] {
  var failures=[String](),warnings=[String]()
  var cancellationAcknowledged=s.controlForward==nil
  if s.controlForward != nil {
   status(Workspace(rawValue:s.module) ?? .devices,.stopping,"取消手机任务","先停止本次任务，再恢复USB和网络服务")
   do{try await cancelPhone(s);cancellationAcknowledged=true}catch{failures.append(error.localizedDescription)}
  }
  if s.ncmBorrowed==true {log("phoneInternet","existingSharingPreserved","本次没有申请原usb0共享，停止不会关闭系统原共享")}
  if let change=ncmServiceChange,change.id==s.id {
   do{try await change.task.value}catch{log("phoneInternet","pendingServiceChange",error.localizedDescription)}
   ncmServiceChange=nil
  }
  // Restore the Mac service even if the phone has been unplugged. Only a
  // service this session enabled from Disabled is disabled again.
  for receipt in (s.ncmServices ?? []).reversed() {
   do{try await ncmServices().restore(receipt)}catch{failures.append(error.localizedDescription)}
  }
  if let change=ncmUSBChange,change.id==s.id {
   do{try await change.task.value}catch{log("phoneInternet","pendingUSBChange",error.localizedDescription)}
   ncmUSBChange=nil
  }
  if let pid=s.relayPID,let executable=s.relayExecutable {
   do {
    let process=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/ps"),["-p",String(pid),"-o","command="],timeout:2,cancellable:false)
    if process.code==0 {
     guard process.output.contains(executable),process.output.contains("-DUSBLinkMic.session=\(s.id)") else{throw LinkError.failure("PROCESS_OWNERSHIP_CHANGED","原PID已被其他进程使用，未终止")}
     kill(pid,SIGTERM)
     try? await Task.sleep(nanoseconds:300_000_000)
     let remaining=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/ps"),["-p",String(pid),"-o","command="],timeout:2,cancellable:false)
     if remaining.code==0,remaining.output.contains(executable),remaining.output.contains("-DUSBLinkMic.session=\(s.id)"){kill(pid,SIGKILL)}
    }
   }catch{failures.append(error.localizedDescription)}
  }
  if let functions=s.oldUSB {do{
   let driver=ncmDriver()
   try await driver.waitForDevice(s.serial,seconds:3,respectCancellation:false)
   var recoveryErrors=[String]()
   if s.ncmRequested==true {
    // The helper has a 30s process watchdog. Wait through its final receipt before
    // submitting stop; cancellation cannot leave a late start racing restoration.
    if let pending=s.ncmPendingStart {
     do{_ = try await driver.result(at:pending,serial:s.serial,session:s.id,respectCancellation:false)}
     catch{
      let processes=try await adb.run(s.serial,["shell","ps","-A","-o","ARGS"],timeout:4)
      guard !processes.split(separator:"\n").contains(where:{$0.contains("com.zjx.usblinkmic.platform.NcmShellCommand") && $0.contains(s.id)}) else{throw LinkError.failure("NCM_START_PENDING","手机共享启动进程仍未结束，保留恢复记录")}
      log("phoneInternet","startReceiptMissing","启动进程已结束但回执不可读，仍执行停止与USB恢复")
     }
    }
    do {
     let path="/data/local/tmp/usblinkmic-\(s.id)-stop.json"
     try await driver.launch("stop",serial:s.serial,session:s.id,resultPath:path)
     let receipt=try await driver.result(at:path,serial:s.serial,session:s.id,respectCancellation:false)
     try NCMDriver.requireSuccess(receipt,action:"stop")
     try await driver.waitForTethering(serial:s.serial,session:s.id,active:false,respectCancellation:false)
    }catch{recoveryErrors.append(error.localizedDescription)}
   }
   do {
    let usb=try await driver.usbState(s.serial)
    log("phoneInternet","usbRestoreBaseline",usb.summary)
    guard let current=usb.active else{throw LinkError.failure("USB_STATE_UNKNOWN","无法读取恢复前的实际USB功能，保留恢复记录")}
    let active=NCMDriver.functions(current),original=NCMDriver.functions(functions)
    guard active==original || (active.contains("ncm") && active.subtracting(["ncm","adb"]).isEmpty) else{throw LinkError.failure("USB_OWNERSHIP_CHANGED","用户或系统已改变USB功能，未覆盖后续更改")}
    if active != original {
     status(.phoneInternet,.stopping,"恢复USB模式","等待本次USB重枚举与实际功能确认")
     try await driver.setFunctions(functions,serial:s.serial,respectCancellation:false,reconnectSeconds:5,confirmationSeconds:5)
    } else {log("phoneInternet","usbAlreadyRestored","USB已是原值，未重复切换")}
   }catch{recoveryErrors.append(error.localizedDescription)}
   for path in recoveryErrors.isEmpty ? (s.ncmResults ?? []) : [] {
    do{try await driver.removeResult(path,serial:s.serial,session:s.id)}catch{recoveryErrors.append(error.localizedDescription)}
   }
   if !recoveryErrors.isEmpty {throw LinkError.failure("NCM_RECOVERY_INCOMPLETE",recoveryErrors.joined(separator:"；"))}
  }catch{failures.append(error.localizedDescription)}}
  if s.oldUSB != nil {
   do {
    let route=try await NetworkProbe.defaultInterface()
    if route != s.originalInterface {
     let warning="系统默认出口与开始时不同：原=\(s.originalInterface ?? "none")，当前=\(route ?? "none")；请检查系统网络设置"
     warnings.append(warning);log("phoneInternet","routeObservation",warning)
    }
   }catch {warnings.append("默认出口读取失败："+error.localizedDescription)}
  }
  if let port=s.controlForward {
   // Retain the control channel and journal until an authenticated cancellation
   // is acknowledged. An exit-zero `am start` is not a business receipt.
   if cancellationAcknowledged {
   do{
    let mappings=try await adb.run(nil,["forward","--list"],timeout:3)
    let local="tcp:\(port)"
    if mappings.split(separator:"\n").contains(where:{$0.split(whereSeparator:{$0.isWhitespace}).contains(Substring(local))}) {
     guard let target=s.controlTarget,ADB.ownsMapping(mappings,serial:s.serial,local:local,remote:"tcp:\(target)") else{throw LinkError.failure("OWNERSHIP_CHANGED","控制转发归属已改变，未删除")}
     _ = try await adb.run(s.serial,["forward","--remove",local],timeout:3)
    }
   }catch{failures.append(error.localizedDescription)}
   }
  }
  if let reverse=s.reverse {do{
   let mappings=try await adb.run(s.serial,["reverse","--list"],timeout:3)
   let target=s.module==Workspace.macInternet.rawValue ? "tcp:48128":reverse
   let lines=mappings.split(separator:"\n").map{$0.split(whereSeparator:{$0.isWhitespace}).map(String.init)}
   if let match=lines.first(where:{$0.count>=3 && $0[1]==reverse}) {
    guard match[2]==target else{throw LinkError.failure("OWNERSHIP_CHANGED","USB反向映射已被修改，未删除")}
    _ = try await adb.run(s.serial,["reverse","--remove",reverse],timeout:3)
   }
  }catch{failures.append(error.localizedDescription)}}
  if !failures.isEmpty {throw LinkError.failure("CLEANUP_INCOMPLETE",failures.joined(separator:"；"))}
  return warnings
 }
 private func cancelPhone(_ s:OwnedSession) async throws {
  guard let port=s.controlForward,let target=s.controlTarget,(1...65535).contains(port),(1...65535).contains(target) else{throw LinkError.failure("CONTROL_FORWARD","取消回执缺少有效控制端口")}
  let mappings=try await adb.run(nil,["forward","--list"],timeout:3)
  let local="tcp:\(port)"
  if !ADB.ownsMapping(mappings,serial:s.serial,local:local,remote:"tcp:\(target)") {
   guard !mappings.split(separator:"\n").contains(where:{$0.split(whereSeparator:{$0.isWhitespace}).dropFirst().first==Substring(local)}) else{throw LinkError.failure("OWNERSHIP_CHANGED","取消控制端口已被其他会话使用，未覆盖")}
   _ = try await adb.run(s.serial,["forward","--no-rebind",local,"tcp:\(target)"],timeout:3)
  }
  func acknowledged(_ response:[String:Any])->Bool {response["protocol"] as? Int==4 && response["session"] as? String==s.id && response["cancelAccepted"] as? Bool==true && response["producerStopped"] as? Bool==true}
  var accepted=false
  do {
   let response=try await ControlClient.request(port:port,body:["command":"stop","session":s.id,"token":s.token])
   accepted=response["session"] as? String==s.id && response["cancelAccepted"] as? Bool==true
   if acknowledged(response) {log(s.module,"cancelAcknowledged","取消已接受，生产者已停止；继续恢复资源");return}
  }
  catch {log(s.module,"cancelControlPending",error.localizedDescription)}
  if !accepted {
  let capabilities=try await adb.run(s.serial,["shell","content","call","--uri","content://com.zjx.usblinkmic.capabilities","--method","capabilities"],timeout:3)
  let component=Self.compatibleCompanion(capabilities) ? Capabilities.androidControlComponent:(s.controlComponent ?? Capabilities.legacyAndroidControlComponent)
  let launch=try await adb.run(s.serial,["shell","am","start","-f","0x18000000","-n",component,"--es","mode","cancel","--es","session",s.id,"--es","token",s.token,"--ei","controlPort",String(target)],timeout:4)
  log(s.module,"phoneCancelLaunch",launch)
  guard launch.range(of:#"Error:|Error type|SecurityException|Permission Denial|Exception occurred"#,options:[.regularExpression,.caseInsensitive])==nil else{throw LinkError.failure("CONTROL_CANCEL_REJECTED",launch)}
  }
  let deadline=ProcessInfo.processInfo.systemUptime+8
  repeat {
   do {if acknowledged(try await ControlClient.request(port:port,body:["command":"status","session":s.id,"token":s.token])) {log(s.module,"cancelAcknowledged","手机已确认本次取消");return}}
   catch {log(s.module,"cancelReceiptPending",error.localizedDescription)}
   try await Task.sleep(nanoseconds:300_000_000)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("STOP_NOT_ACKNOWLEDGED","手机未确认取消；保留控制通道与恢复记录，请重试停止")
 }
 public func stop(_ module:Workspace) async {
  if recovering,let recovery=recoveryJob {await recovery.value}
  if let job=stopJobs[module] {await job.value;return}
  jobs[module]?.cancel();jobs[module]=nil;jobIDs[module]=nil
  guard let session=owned[module] else{return}
  stopping.insert(module)
  // A separate, uncancelled cleanup task is shared by Stop, Save and Quit.
  // Keep ownership in the durable journal throughout every suspension point.
  let job=Task {await finishStop(module,session)}
  stopJobs[module]=job
  await job.value
 }
 private func finishStop(_ module:Workspace,_ session:OwnedSession) async {
  let began=ProcessInfo.processInfo.systemUptime
  defer{log(module.rawValue,"stopDuration","elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-began))s, resourcesRemaining=\(owned[module] != nil)");stopping.remove(module);stopJobs[module]=nil}
  status(module,.stopping,"正在停止")
  if module == .microphone {receiver.stop();output.stop();snapshot.level=0;snapshot.waveform=[];snapshot.audioState = .disconnected;audioWatchdog.stop(session.id);snapshot.receivedFrames=0;snapshot.effectiveAudio=nil}
  if module == .phoneInternet {
   ncmMonitor?.cancel();ncmMonitor=nil;ncmInterface=nil;snapshot.networkState = .stopped
   if session.oldUSB != nil,owned[.microphone] != nil,snapshot.settings.transport == .usb {await stop(.microphone)}
  }
  if module == .macInternet {relay?.terminationHandler=nil;if relay?.isRunning==true {relay?.terminate()};relay=nil;snapshot.networkState = .stopped}
  do {
   try saveJournal()
   let warnings=try await cleanup(session)
   owned[module]=nil
   try saveJournal()
   status(module,.stopped,"已停止",warnings.joined(separator:"；"))
  } catch {
   owned[module]=session
   do{try saveJournal()}catch{log("recovery","journalSaveFailed",error.localizedDescription)}
   if module == .microphone {snapshot.audioState = .failed}else{snapshot.networkState = .failed}
   status(module,.failed,"资源恢复待重试，请点击全部停止",error.localizedDescription,"CLEANUP_INCOMPLETE")
  }
 }
 public func stopAll() async {for module in [Workspace.microphone,.phoneInternet,.macInternet] {await stop(module)}}
 public func shutdown() async -> Bool {
  quitting=true;await stopAll()
  guard owned.isEmpty,stopping.isEmpty,stopJobs.isEmpty,!recoveryBlocked else{quitting=false;return false}
  timer?.cancel();deviceMonitor?.cancel();return true
 }
 private func exportLogs() {
  let panel=NSSavePanel();panel.nameFieldStringValue="USBLinkMic-diagnostics.txt"
  if panel.runModal() == .OK,let url=panel.url {do{let text=try diagnosticLog.exportText();try LogRedactor.redact(text).write(to:url,atomically:true,encoding:.utf8)}catch{log("logs","exportFailed",error.localizedDescription)}}
 }
}
