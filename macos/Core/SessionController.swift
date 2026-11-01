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

private struct AudioDeliveryUpdate: Sendable {
 let packets: UInt64
 let receivedAt: TimeInterval
 let level: Double
 let waveform: [Double]
}

/// PCM is produced only on the receiver's serial queue. The lock protects a
/// single UI mailbox; a busy main actor can never hold up audio or collect tasks.
private final class AudioDelivery: @unchecked Sendable {
 private let input: AudioOutputInput
 private var packets: UInt64 = 0
 private var lastMeterAt: TimeInterval = 0
 private var failed = false
 private let mailboxLock = NSLock()
 private var latestUpdate: AudioDeliveryUpdate?
 private var updateScheduled = false
 private var latestProgress: (packets: UInt64, receivedAt: TimeInterval)?

 init(input: AudioOutputInput) { self.input = input }

 /// Returns true only when the caller needs to schedule a UI mailbox drain.
 func consume(_ frames: [Data]) throws -> Bool {
  guard !failed else { return false }
  let now = ProcessInfo.processInfo.systemUptime
  let measure = now - lastMeterAt >= 0.1
  var meter: (level: Double, trend: [Double])?
  do {
   for (index, data) in frames.enumerated() {
    let value = try input.consume(data, measure: measure && index == frames.count - 1)
    packets &+= 1
    if measure && index == frames.count - 1 { meter = value }
   }
  } catch {
   failed = true
   throw error
  }
  mailboxLock.lock()
  latestProgress = (packets, now)
  mailboxLock.unlock()
  guard let meter else { return false }
  lastMeterAt = now
  let update = AudioDeliveryUpdate(packets: packets, receivedAt: now, level: meter.level, waveform: meter.trend)
  mailboxLock.lock()
  defer { mailboxLock.unlock() }
  latestUpdate = update
  guard !updateScheduled else { return false }
  updateScheduled = true
  return true
 }

 func takeUpdate() -> AudioDeliveryUpdate? {
  mailboxLock.lock()
  defer { mailboxLock.unlock() }
  let update = latestUpdate
  latestUpdate = nil
  updateScheduled = false
  return update
 }

 func progress() -> (packets: UInt64, receivedAt: TimeInterval)? {
  mailboxLock.lock()
  defer { mailboxLock.unlock() }
  return latestProgress
 }
}

@MainActor public final class SessionController: ObservableObject, AppControlling {
 @Published public private(set) var snapshot=AppSnapshot()
 public let telemetry=AudioTelemetry()
 public let bootID=String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8)).lowercased()
 private let store:SettingsStore
 private let root:URL
 private let adb:ADB
 private let journal:URL
 private let diagnosticLog:DiagnosticLog
 private var owned:[Workspace:OwnedSession]=[:]
 private(set) var activeSessions:[Workspace:String]=[:]
 private var deviceAliases:[String:String]=[:]
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
 private var audioDeviceObserver:AudioDeviceObserver?
 private var lastDefaultOutputUID:String?
 private var audioDelivery: (id: String, delivery: AudioDelivery)?
 private var relay:Process?
 private var audioWatchdog=AudioSessionWatchdog()
 private var failingAudioSessions=Set<String>()
 // User intent outlives a transport session but never an explicit stop/device change.
 private(set) var microphoneIntent: UUID?
 private(set) var microphoneIntentSerial: String?
 private var audioRecovery: Task<Void,Never>?
 private var audioForwardChange: (id:String,task:Task<String,Error>)?
 private var audioRecoveryID: UUID?
 private var audioRetryCount = 0
 private var audioMetricsAt: TimeInterval = 0
 private var audioPollAt: TimeInterval = 0
 private var audioPacketCount: UInt64 = 0
 private var lastSnapshotTelemetryAt: TimeInterval = 0
 private var lastRenderCallbacks=0
 private var renderProgressAt:TimeInterval=0
 private var outputRestartCount=0
 private var audioAnomalyAt:TimeInterval=0
 private var lastDroppedFrames=0
 private var lastBacklogFrames=0
 private var phoneAudioDiagnostics = "unknown"
 private var phoneSilenced: Bool?
 private var audioControlFailures = 0
 private var deferredNetworkResume: UUID?
 private var lastGainLogAt: TimeInterval = 0
 private var lastRefreshErrorText = ""
 private var lastRefreshErrorAt: TimeInterval = 0
 private var isRefreshingDevices = false
 private var adbServerWarm = false
 private var networkHealthSummaryAt: TimeInterval = 0

 private var timer:Task<Void,Never>?
 private var deviceMonitor:Task<Void,Never>?
 private var ncmMonitor:Task<Void,Never>?
 private let processGroup=ProcessGroupCancellation()
 private var shutdownTask:Task<Bool,Never>?
 private var shutdownCleanupAttempted=Set<Workspace>()
 private var shutdownDeadlineExpired=false
 private var booted=false
 private(set) var recovering=true
 private var recoveryBlocked=false
 private var quitting=false
 private var diagnosticsClosed=false
 private var onboardingURL:URL {journal.deletingLastPathComponent().appendingPathComponent("onboarding.json")}
 public init(resourceRoot:URL?=nil, stateDirectory:URL?=nil) {
  root=resourceRoot ?? Bundle.main.resourceURL ?? URL(fileURLWithPath:"/nonexistent")
  adb=ADB(executable:root.appendingPathComponent("platform-tools/adb"))
  let directory=stateDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("USBLinkMic-v4")
  store=SettingsStore(url:directory.appendingPathComponent("settings.json"));journal=directory.appendingPathComponent("owned-sessions.json")
  diagnosticLog=DiagnosticLog(url:directory.appendingPathComponent("diagnostics.log"))
  do {snapshot.settings=try store.load()} catch {snapshot.recoveryMessage="配置加载失败：\(error.localizedDescription)"}
  do {snapshot.logs=Array(try diagnosticLog.load().suffix(500))} catch {snapshot.recoveryMessage="历史日志读取失败：\(error.localizedDescription)"}
  let initialOutputs=AudioOutput.devices(forceRefresh:true)
  snapshot.outputs=initialOutputs
  lastDefaultOutputUID=AudioOutput.defaultOutputUID(forceRefresh:true)
  if let data=try? Data(contentsOf:onboardingURL),let flags=try? JSONDecoder().decode([String:Bool].self,from:data){snapshot.wizardSkipped=flags["skipped"] ?? false;snapshot.soundTestCompleted=flags["soundTest"] ?? false}
 }
 public func boot() {
  guard !booted,!quitting else{return};booted=true
  log("system","appBoot","version=\(Capabilities.version), build=40015, protocol=\(Capabilities.protocolVersion), runtimeRev=\(Capabilities.runtimeRevision), boot=\(bootID)")
  let observer=AudioDeviceObserver { [weak self] deviceSnapshot in
   self?.handleAudioDeviceSnapshot(deviceSnapshot)
  }
  audioDeviceObserver=observer
  observer.start()
  ProcessRunner.$currentGroup.withValue(processGroup) {
   recoveryJob=Task {await recover();recovering=false;recoveryJob=nil;if !quitting {await refresh()}}
   timer=Task {while !Task.isCancelled,!quitting {try? await Task.sleep(nanoseconds:1_000_000_000);if !Task.isCancelled,!quitting {await tick()}}}
   deviceMonitor=Task {while !Task.isCancelled,!quitting {try? await Task.sleep(nanoseconds:3_000_000_000);if !Task.isCancelled,!quitting,!recovering {await refresh()}}}
  }
 }
 private func deviceAlias(_ serial:String) -> String {
  guard !serial.isEmpty else { return "none" }
  if let existing=deviceAliases[serial] { return existing }
  let alias="dev#\(deviceAliases.count + 1)"
  deviceAliases[serial]=alias
  return alias
 }
 private func currentOutputs(forceRefresh:Bool=false) -> [OutputDevice] {
  if forceRefresh || AudioOutput.devicesProvider != nil {
   let fresh=AudioOutput.devices(forceRefresh:true)
   let defaultUID=AudioOutput.defaultOutputUID(forceRefresh:true)
   handleAudioDeviceSnapshot(AudioDeviceSnapshot(devices:fresh,defaultOutputUID:defaultUID))
   return snapshot.outputs
  }
  return snapshot.outputs
 }
 internal func handleAudioDeviceSnapshot(_ deviceSnapshot:AudioDeviceSnapshot) {
  guard !quitting,!shutdownDeadlineExpired else { return }
  let newOutputs=deviceSnapshot.devices
  let previousOutputs=snapshot.outputs
  if newOutputs != previousOutputs {
   let previousIDs=Set(previousOutputs.map(\.id))
   let newIDs=Set(newOutputs.map(\.id))
   let added=newOutputs.filter { !previousIDs.contains($0.id) }.map { "\($0.name)" }
   let removed=previousOutputs.filter { !newIDs.contains($0.id) }.map { "\($0.name)" }
   snapshot.outputs=newOutputs
   log("audio","outputsChanged","count=\(newOutputs.count), added=[\(added.joined(separator:","))], removed=[\(removed.joined(separator:","))], selected=\(snapshot.settings.outputUID)")
   if let id=activeSessions[.microphone],snapshot.settings.outputUID != "default",!newOutputs.contains(where:{$0.id==snapshot.settings.outputUID}) {
    Task { await failAudio(id,"OUTPUT_REMOVED: 指定输出离线，已停止，避免自动外放") }
   } else if snapshot.settings.outputUID != "default",!previousIDs.contains(snapshot.settings.outputUID),newIDs.contains(snapshot.settings.outputUID) {
    log("audio","selectedOutputOnline","output=\(snapshot.settings.outputUID)")
    if snapshot.microphone.phase == .failed,(snapshot.microphone.detail.contains("OUTPUT_REMOVED") || snapshot.microphone.detail.contains("OUTPUT_MISSING")) {
     status(.microphone,.failed,"输出设备已恢复连接","所选输出设备已重新上线，可点击开始恢复麦克风","OUTPUT_RECONNECTED")
    }
   }
  }
  if deviceSnapshot.defaultOutputUID != lastDefaultOutputUID {
   let previousDefault=lastDefaultOutputUID
   lastDefaultOutputUID=deviceSnapshot.defaultOutputUID
   if previousDefault != nil || deviceSnapshot.defaultOutputUID != nil {
    log("audio","defaultOutputChanged","from=\(previousDefault ?? "none"), to=\(deviceSnapshot.defaultOutputUID ?? "none"), selected=\(snapshot.settings.outputUID)")
    if let id=activeSessions[.microphone],valid(.microphone,id),snapshot.settings.outputUID == "default",audioRecovery == nil {
     do {
      try output.restartCurrentDevice(snapshot.settings)
      lastRenderCallbacks=output.statistics.renderCallbacks
      renderProgressAt=ProcessInfo.processInfo.systemUptime
      log("audio","defaultOutputSwitched","session=\(id), defaultOutput=\(deviceSnapshot.defaultOutputUID ?? "default")")
     } catch {
      log("audio","defaultOutputSwitchFailed","session=\(id), reason=\(error.localizedDescription)")
     }
    }
   }
  }
 }
 public func send(_ action:UserAction) {
  send(action,source:.ui)
 }
 public func send(_ action:UserAction, source:ActionSource) {
  guard !quitting else{return}
  ProcessRunner.$currentGroup.withValue(processGroup) {
   switch action {
   case .refresh:
    log("devices","userAction","source=\(source.rawValue), action=refresh")
    Task{await refresh(manual:true,source:source)}
   case .selectDevice(let serial):
    let prev=snapshot.selectedDeviceID ?? ""
    if serial != snapshot.selectedDeviceID {
     log("devices","userAction","source=\(source.rawValue), action=selectDevice, from=\(deviceAlias(prev)), to=\(deviceAlias(serial))")
     revokeMicrophoneIntent("deviceChanged")
     Task{await stop(.microphone,source:source)}
    }
    snapshot.selectedDeviceID=serial
   case .start(let module):
    log(module.rawValue,"userAction","source=\(source.rawValue), action=start, device=\(deviceAlias(snapshot.selectedDeviceID ?? "")), transport=\(snapshot.settings.transport.rawValue)")
    if module == .microphone,owned[module]==nil,jobs[module]==nil {revokeMicrophoneIntent("newStart");microphoneIntent=UUID();microphoneIntentSerial=snapshot.selectedDeviceID;audioRetryCount=0}
    if module == .microphone,usbNetworkTransition {
     deferredNetworkResume=microphoneIntent
     log("audio","startDeferred","source=\(source.rawValue), USB网络切换尚未完成，录音开始请求等待切换收尾")
     return
    }
    start(module)
   case .stop(let module):
    log(module.rawValue,"userAction","source=\(source.rawValue), action=stop, session=\(owned[module]?.id ?? "none")")
    if module == .microphone {revokeMicrophoneIntent("userStop")}
    Task{await stop(module,source:source)}
   case .stopAll:
    log("system","userAction","source=\(source.rawValue), action=stopAll, owned=[\(owned.keys.map(\.rawValue).sorted().joined(separator:","))]")
    revokeMicrophoneIntent("userStopAll")
    Task{await stopAll(source:source)}
   case .saveSettings(let settings):
    handleSaveSettings(settings,source:source)
   case .setGain(let gain):
    guard gain.isFinite,(0...4).contains(gain) else{return}
    snapshot.settings.gain=gain;output.gain=Float(gain)
    let now=ProcessInfo.processInfo.systemUptime
    if now-lastGainLogAt>=0.5 {
     lastGainLogAt=now
     log("audio","userGain","source=\(source.rawValue), gain=\(String(format:"%.2f",gain))")
    }
   case .setMuted(let muted):
    snapshot.settings.muted=muted;output.muted=muted;log("audio","userMute","source=\(source.rawValue), muted=\(muted)")
   case .skipWizard:
    snapshot.wizardSkipped=true;saveOnboarding();log("wizard","userAction","source=\(source.rawValue), action=skipWizard")
   case .completeSoundTest:
    if max(snapshot.receivedFrames,telemetry.receivedFrames)>0,snapshot.microphone.phase == .running {
     snapshot.soundTestCompleted=true;saveOnboarding();log("wizard","userAction","source=\(source.rawValue), action=completeSoundTest")
    }
   case .clearLogs:
    do{try diagnosticLog.clear();snapshot.logs=[]}catch{log("logs","clearFailed",error.localizedDescription)}
   case .exportLogs:
    log("logs","userAction","source=\(source.rawValue), action=exportLogs")
    exportLogs()
   case .openDriverHelp:
    log("audio","userAction","source=\(source.rawValue), action=openDriverHelp")
    NSWorkspace.shared.open(URL(string:"https://existential.audio/blackhole/")!)
   case .openPhoneSettings:
    log("permission","userAction","source=\(source.rawValue), action=openPhoneSettings, device=\(deviceAlias(snapshot.selectedDeviceID ?? ""))")
    if let serial=snapshot.selectedDeviceID {Task{do{_ = try await adb.run(serial,["shell","am","start","-a","android.settings.APPLICATION_DETAILS_SETTINGS","-d","package:com.zjx.usblinkmic"])}catch{log("permission","failed",error.localizedDescription)}}}
   }
  }
 }
 private func handleSaveSettings(_ settings:Settings, source:ActionSource) {
  guard !snapshot.isSavingSettings else {
   log("settings","saveIgnored","source=\(source.rawValue), reason=saveInProgress")
   return
  }
  let began=ProcessInfo.processInfo.systemUptime
  let current=snapshot.settings
  let changedKeys=SettingsValidator.changedKeys(from:current,to:settings)
  let activeMicTransport:AudioTransport? = (activeSessions[.microphone] != nil || jobs[.microphone] != nil) ? current.transport : nil
  let affected=SettingsValidator.affectedWorkspaces(from:current,to:settings,activeMicrophoneTransport:activeMicTransport)
  let checkOutputs=SettingsValidator.requiresOutputValidation(from:current,to:settings,microphoneActive:activeSessions[.microphone] != nil)
  var errors=SettingsValidator.errors(settings)+(checkOutputs ? SettingsValidator.outputErrors(settings,outputs:currentOutputs(forceRefresh:true)) : [])
  if settings.transport == .wifi {
   let activeLan: Set<String>? = snapshot.lanCandidates.isEmpty ? nil : Set(snapshot.lanCandidates)
   for err in SettingsValidator.wifiEndpointErrors(settings, activeLanAddresses: activeLan) where !errors.contains(err) {
    errors.append(err)
   }
  }
  guard errors.isEmpty else {
   let msg=errors.joined(separator:"；")
   snapshot.settingsError=msg
   snapshot.settingsMessage=msg
   log("settings","invalid","source=\(source.rawValue), keys=[\(changedKeys.joined(separator:","))], error=\(msg)")
   return
  }
  if affected.contains(.microphone) {
   revokeMicrophoneIntent("settingsChange")
  }
  let affectedOrdered=[Workspace.microphone,.phoneInternet,.macInternet].filter { affected.contains($0) }
  let pendingInactive=[Workspace.microphone,.phoneInternet,.macInternet].filter { !affected.contains($0) && activeSessions[$0]==nil && jobs[$0]==nil && owned[$0] != nil }
  let modulesToStop=affectedOrdered.filter { owned[$0] != nil || jobs[$0] != nil } + pendingInactive
  if modulesToStop.isEmpty && affectedOrdered.allSatisfy({ owned[$0] == nil }) {
   do {
    try store.save(settings)
    snapshot.settings=settings
    output.gain=Float(settings.gain)
    output.muted=settings.muted
    snapshot.isSavingSettings=false
    snapshot.settingsError=nil
    snapshot.settingsSavedRevision &+= 1
    snapshot.settingsMessage="设置已保存，请点击开始重新连接"
    log("settings","saved","source=\(source.rawValue), keys=[\(changedKeys.joined(separator:","))], affected=[\(affectedOrdered.map(\.rawValue).joined(separator:","))], stopped=[], elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))")
   } catch {
    let msg="设置保存失败：\(error.localizedDescription)"
    snapshot.isSavingSettings=false
    snapshot.settingsError=msg
    snapshot.settingsMessage=msg
    log("settings","failed","source=\(source.rawValue), keys=[\(changedKeys.joined(separator:","))], elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000)), error=\(msg)")
   }
   return
  }
  snapshot.isSavingSettings=true
  snapshot.settingsError=nil
  snapshot.settingsMessage=modulesToStop.isEmpty ? "正在保存设置" : "正在停止连接并保存设置"
  log("settings","saveStarted","source=\(source.rawValue), keys=[\(changedKeys.joined(separator:","))], affected=[\(affectedOrdered.map(\.rawValue).joined(separator:","))], stopping=[\(modulesToStop.map(\.rawValue).joined(separator:","))]")
  Task {
   defer{snapshot.isSavingSettings=false}
   for module in modulesToStop {
    await stop(module,source:.settings)
   }
   let remainingAffected=affectedOrdered.filter { owned[$0] != nil }
   guard remainingAffected.isEmpty else {
    let msg="停止未完成，设置未保存；请重试全部停止"
    snapshot.settingsError=msg
    snapshot.settingsMessage=msg
    log("settings","failed","source=\(source.rawValue), keys=[\(changedKeys.joined(separator:","))], affected=[\(affectedOrdered.map(\.rawValue).joined(separator:","))], remaining=[\(remainingAffected.map(\.rawValue).joined(separator:","))], elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000)), error=\(msg)")
    return
   }
   do {
    try store.save(settings)
    snapshot.settings=settings
    output.gain=Float(settings.gain)
    output.muted=settings.muted
    snapshot.settingsError=nil
    snapshot.settingsSavedRevision &+= 1
    snapshot.settingsMessage="设置已保存，请点击开始重新连接"
    log("settings","saved","source=\(source.rawValue), keys=[\(changedKeys.joined(separator:","))], affected=[\(affectedOrdered.map(\.rawValue).joined(separator:","))], stopped=[\(modulesToStop.map(\.rawValue).joined(separator:","))], elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))")
   } catch {
    let msg="设置保存失败：\(error.localizedDescription)"
    snapshot.settingsError=msg
    snapshot.settingsMessage=msg
    log("settings","failed","source=\(source.rawValue), keys=[\(changedKeys.joined(separator:","))], elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000)), error=\(msg)")
   }
  }
 }
 private func saveOnboarding(){do{try FileManager.default.createDirectory(at:onboardingURL.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(["skipped":snapshot.wizardSkipped,"soundTest":snapshot.soundTestCompleted]).write(to:onboardingURL,options:.atomic)}catch{log("wizard","saveFailed",error.localizedDescription)}}
 private func log(_ module:String,_ stage:String,_ text:String){guard !diagnosticsClosed else{return};var safe=text;for serial in Set(snapshot.devices.map{$0.id}+owned.values.map{$0.serial}+[snapshot.selectedDeviceID ?? ""]) where !serial.isEmpty {safe=safe.replacingOccurrences(of:serial,with:"serial=[REDACTED]")};for credential in Set(owned.values.map{$0.token}+[snapshot.settings.pairingCode]) where !credential.isEmpty {safe=safe.replacingOccurrences(of:credential,with:"[REDACTED]")};let entry=LogEntry(module:module,stage:stage,message:"uptime=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime)) boot=\(bootID) "+String(LogRedactor.redact(safe).prefix(8192)));snapshot.logs.append(entry);diagnosticLog.appendAsync(entry) { [weak self] error in if let error {let message=error.localizedDescription;Task {@MainActor in self?.snapshot.recoveryMessage="诊断日志写入失败：\(message)"}}};if snapshot.logs.count>500 {snapshot.logs.removeFirst(snapshot.logs.count-500)}}
 private func status(_ module:Workspace,_ phase:TaskPhase,_ stage:String,_ detail:String="",_ code:String?=nil) {
  var s=ModuleStatus();s.phase=phase;s.stage=stage;s.detail=detail;s.errorCode=code;s.taskID=owned[module]?.id
  switch module{case .microphone:snapshot.microphone=s;case .phoneInternet:snapshot.phoneInternet=s;case .macInternet:snapshot.macInternet=s;default:break}
  var meta="phase=\(phase.rawValue), session=\(owned[module]?.id ?? "none"), active=\(activeSessions[module] != nil)"
  if let code,!code.isEmpty {meta += ", code=\(code)"}
  if !detail.isEmpty {meta += ", detail=\(detail)"}
  log(module.rawValue,stage,meta)
 }
 private func valid(_ module:Workspace,_ id:String)->Bool{!quitting && !shutdownDeadlineExpired && activeSessions[module]==id && owned[module]?.id==id && !stopping.contains(module) && !Task.isCancelled}
 private func checkCleanupAllowed() throws {
  if shutdownDeadlineExpired || processGroup.isCancelled {
   throw LinkError.failure("CLEANUP_INCOMPLETE","退出清理达到总期限，已保留恢复记录供下次启动恢复")
  }
 }
 private func saveJournal() throws {try FileManager.default.createDirectory(at:journal.deletingLastPathComponent(),withIntermediateDirectories:true);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:journal.deletingLastPathComponent().path);try JSONEncoder().encode(Array(owned.values)).write(to:journal,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)}
 private func recover() async {
  guard FileManager.default.fileExists(atPath:journal.path) else{return}
  let began=ProcessInfo.processInfo.systemUptime
  do {
   let sessions=try JSONDecoder().decode([OwnedSession].self,from:Data(contentsOf:journal))
   var recovered=[Workspace:OwnedSession]()
   for session in sessions {
    guard let module=Workspace(rawValue:session.module),[Workspace.microphone,.phoneInternet,.macInternet].contains(module),recovered[module]==nil else{throw LinkError.failure("JOURNAL_INVALID","恢复记录包含未知或重复任务，保留原记录")}
    recovered[module]=session
   }
   owned=recovered
   activeSessions.removeAll()
   if !sessions.isEmpty {
    log("recovery","started","count=\(sessions.count), modules=[\(sessions.map(\.module).joined(separator:","))]")
   }
   var errors=[String]()
   for session in sessions {
    guard !shutdownDeadlineExpired else { break }
    guard let module=Workspace(rawValue:session.module) else{continue}
    let sessionBegan=ProcessInfo.processInfo.systemUptime
    do {
     if quitting { shutdownCleanupAttempted.insert(module) }
     let warnings=try await cleanup(session)
     if quitting { shutdownCleanupAttempted.insert(module) }
     guard !shutdownDeadlineExpired else {
      throw LinkError.failure("CLEANUP_INCOMPLETE","退出清理达到总期限，保留恢复记录")
     }
     owned[module]=nil;try saveJournal();if !warnings.isEmpty {log(module.rawValue,"recoveryWarning","session=\(session.id), warnings=\(warnings.joined(separator:"；"))")}
     log(module.rawValue,"recovered","session=\(session.id), elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-sessionBegan)*1000)), 上次会话资源已清理；未重新开始任务")
    }catch {
     if quitting { shutdownCleanupAttempted.insert(module) }
     owned[module]=session
     activeSessions[module]=nil
     errors.append(error.localizedDescription)
     status(module,.failed,"上次资源恢复待重试，请点击全部停止",error.localizedDescription,"CLEANUP_INCOMPLETE")
    }
   }
   try saveJournal()
   if !sessions.isEmpty {
    snapshot.recoveryMessage=errors.isEmpty ? "上次会话资源已清理；未恢复录音":"上次资源清理未完成："+errors.joined(separator:"；")
    log("recovery","completed","elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000)), remaining=[\(owned.keys.map(\.rawValue).sorted().joined(separator:","))], errors=\(errors.count)")
   }
  }catch {
   recoveryBlocked=true;snapshot.recoveryMessage="恢复记录读取或保存失败：\(error.localizedDescription)"
   log("recovery","failed",snapshot.recoveryMessage)
  }
 }
 private func refresh(manual:Bool=false, source:ActionSource = .system) async {
  guard !quitting,!Task.isCancelled else{return}
  if manual || AudioOutput.devicesProvider != nil {
   _ = currentOutputs(forceRefresh:true)
  }
  if manual || snapshot.lanCandidates.isEmpty {
   let lan = await NetworkProbe.probeWifiTargetHost(
    configuredHost: snapshot.settings.wifiHost,
    listenAddress: snapshot.settings.listenAddress,
    additionalExcludedInterfaces: ncmInterface.map { [$0] } ?? []
   )
   snapshot.lanCandidates = lan.candidates.map(\.address)
  }
  guard !isRefreshingDevices else { return }
  isRefreshingDevices = true
  defer { isRefreshingDevices = false }
  do {
   let adbTimeout: TimeInterval = adbServerWarm ? 4 : 6
   let text=try await adb.run(nil,["devices","-l"],timeout:adbTimeout,cancellable:true)
   adbServerWarm = true
   guard !quitting,!Task.isCancelled else{return}
   let parsed=ADB.devices(text).map{Device(id:$0.0,name:$0.0,state:$0.1=="device" ? .online:($0.1=="unauthorized" ? .unauthorized:.offline))}
   for dev in parsed { _ = deviceAlias(dev.id) }
   if parsed != snapshot.devices {
    let summary=parsed.map { "\(deviceAlias($0.id)):\($0.state.rawValue)" }.joined(separator:",")
    snapshot.devices=parsed
    log("devices","updated","source=\(source.rawValue), count=\(parsed.count), list=[\(summary)]")
   }
   if snapshot.selectedDeviceID==nil,snapshot.devices.count==1 {
    snapshot.selectedDeviceID=snapshot.devices.first?.id
    if let autoID=snapshot.selectedDeviceID {
     log("devices","autoSelected","device=\(deviceAlias(autoID))")
    }
   }
   lastRefreshErrorText=""
  }catch{
   if !quitting,!Task.isCancelled {
    let errText=error.localizedDescription
    let now=ProcessInfo.processInfo.systemUptime
    if manual || errText != lastRefreshErrorText || now-lastRefreshErrorAt>=30 {
     lastRefreshErrorText=errText
     lastRefreshErrorAt=now
     log("devices","failed","source=\(source.rawValue), error=\(errText)")
    }
   }
  }
 }
 private var usbNetworkTransition:Bool {
  snapshot.settings.transport == .usb && owned[.phoneInternet] != nil && snapshot.phoneInternet.phase != .running
 }
 private func start(_ module:Workspace) {
  if module == .microphone,usbNetworkTransition {deferredNetworkResume=microphoneIntent;return}
  guard [.microphone,.phoneInternet,.macInternet].contains(module),jobs[module]==nil,owned[module]==nil,!stopping.contains(module),!snapshot.isSavingSettings,!recovering,!recoveryBlocked,!quitting else{
   log(module.rawValue,"startIgnored","hasJob=\(jobs[module] != nil), hasOwned=\(owned[module] != nil), stopping=\(stopping.contains(module)), saving=\(snapshot.isSavingSettings), recovering=\(recovering), blocked=\(recoveryBlocked)")
   return
  }
  let jobID=UUID().uuidString;jobIDs[module]=jobID
  jobs[module]=ProcessRunner.$currentGroup.withValue(processGroup) {
   Task{guard !Task.isCancelled,jobIDs[module]==jobID else{return};await execute(module);if jobIDs[module]==jobID {jobs[module]=nil;jobIDs[module]=nil}}
  }
 }
 private func execute(_ module:Workspace) async {
  guard !Task.isCancelled,!quitting,!snapshot.isSavingSettings,owned[module]==nil,!stopping.contains(module) else{return}
  let executionIntent=microphoneIntent
  let began=ProcessInfo.processInfo.systemUptime
  let id=UUID().uuidString
  let settings=snapshot.settings
  let token=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
  let sessionToken=(module == .microphone && settings.transport == .wifi) ? settings.pairingCode : token
  let serial=snapshot.selectedDeviceID ?? ""
  if module == .microphone {
   audioWatchdog.begin(id);snapshot.receivedFrames=0;snapshot.effectiveAudio=nil;audioPacketCount=0;lastSnapshotTelemetryAt=0;phoneSilenced=nil;phoneAudioDiagnostics="unknown";audioControlFailures=0;audioMetricsAt=ProcessInfo.processInfo.systemUptime;audioPollAt=0;lastRenderCallbacks=0;renderProgressAt=ProcessInfo.processInfo.systemUptime;outputRestartCount=0;audioAnomalyAt=0;lastDroppedFrames=0;lastBacklogFrames=0
   snapshot.level=0;snapshot.waveform=[];snapshot.audioState = .disconnected;telemetry.reset()
  }
  owned[module]=OwnedSession(id:id,serial:serial,token:sessionToken,module:module.rawValue)
  activeSessions[module]=id
  log(module.rawValue,"sessionStart","session=\(id), device=\(deviceAlias(serial)), transport=\(settings.transport.rawValue)")
  do {
   try saveJournal();status(module,.checking,"检查前置条件")
   let errors=SettingsValidator.errors(settings);guard errors.isEmpty else{throw LinkError.failure("INVALID_SETTINGS",errors.joined(separator:"；"))}
   if module != .microphone || settings.transport == .usb {
    guard !serial.isEmpty else{throw LinkError.failure("DEVICE_REQUIRED","连接USB手机并选择目标")}
    let devices=ADB.devices(try await adb.run(nil,["devices"]))
    adbServerWarm = true
    guard let device=devices.first(where:{$0.0==serial}) else{throw LinkError.failure("DEVICE_DISCONNECTED","所选手机未连接")}
    guard device.1=="device" else{throw LinkError.failure(device.1=="unauthorized" ? "USB_UNAUTHORIZED":"DEVICE_OFFLINE","请在所选手机确认USB调试授权并重试")}
    try await prepareCompanion(module,id,serial)
   }
   guard valid(module,id) else{return}
   if module == .microphone {try await startAudio(id,serial,settings)}
   else if module == .phoneInternet {await stop(.macInternet);guard owned[.macInternet]==nil else{throw LinkError.failure("DIRECTION_CLEANUP_PENDING","反向供网资源未恢复；先重试停止")};try await startNCM(id,serial,settings)}
   else {await stop(.phoneInternet);guard owned[.phoneInternet]==nil else{throw LinkError.failure("DIRECTION_CLEANUP_PENDING","手机供网资源未恢复；先重试停止")};try await startReverse(id,serial,settings)}
   log(module.rawValue,"sessionReady","session=\(id), elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000)), phase=\(module == .microphone ? snapshot.microphone.phase.rawValue : (module == .phoneInternet ? snapshot.phoneInternet.phase.rawValue : snapshot.macInternet.phase.rawValue))")
  }catch {
   guard owned[module]?.id==id,!Task.isCancelled else{return}
   let message=error.localizedDescription
   let code:String
   if case LinkError.failure(let value,_) = error {code=value}else{code="TASK_FAILED"}
   log(module.rawValue,"operationFailed","session=\(id), code=\(code), elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000)), error=\(message)")
   await stop(module)
   // Retained ownership means cleanup failed. Do not replace that actionable
   // recovery status with the earlier operation error or pretend the task stopped.
   if owned[module] != nil {return}
   if module == .microphone,executionIntent != microphoneIntent {return}
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
  let sessionToken=owned[module]?.token ?? settings.pairingCode
  // NEW_TASK|MULTIPLE_TASK executes the protected transient entry every time.
  // Extras alone do not distinguish Android task identities.
  let args=["shell","am","start","-f","0x18000000","-n",Capabilities.androidControlComponent,"--es","mode",mode,"--es","session",id,"--es","token",sessionToken,"--ei","rate",String(audio.sampleRate),"--ei","channels",String(audio.channels),"--es","format",audio.format.rawValue,"--es","source",audio.source.rawValue,"--ei","port",String(settings.audioPort),"--ei","controlPort",String(settings.controlPort),"--es","dns",settings.dns,"--es","routes",settings.routes]
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
  let outputErrors=SettingsValidator.outputErrors(settings,outputs:currentOutputs(forceRefresh:true))
  guard outputErrors.isEmpty else{throw LinkError.failure("DRIVER_REQUIRED",outputErrors.joined(separator:"；"))}
  var wifiResolvedTarget: WifiTargetResolution?
  if settings.transport == .wifi {
   var excluded = Set<String>()
   if let ncmInterface { excluded.insert(ncmInterface) }
   if let services = try? await ncmServices().list() {
    for svc in services where svc.usbNamed || svc.phoneNamed || NetworkProbe.isUnsuitableWifiHardware(name: svc.name, hardware: svc.hardware) {
     excluded.insert(svc.device)
    }
   }
   if !serial.isEmpty, let phoneIfaces = try? await ncmServices().phoneInterfaces(serial: serial) {
    excluded.formUnion(phoneIfaces)
   }
   let resolvedTarget = await NetworkProbe.probeWifiTargetHost(
    configuredHost: settings.wifiHost,
    listenAddress: settings.listenAddress,
    additionalExcludedInterfaces: excluded
   )
   snapshot.lanCandidates = resolvedTarget.candidates.map(\.address)
   if let errorCode = resolvedTarget.errorCode {
    let detail = resolvedTarget.errorDetail ?? "Wi-Fi 监听与目标地址无效"
    log("microphone", "wifiEndpointInvalid", "session=\(id), code=\(errorCode), listen=\(AudioReceiver.effectiveBindAddress(for: settings)), configuredHost=\(settings.wifiHost), detail=\(detail)")
    throw LinkError.failure(errorCode, detail)
   }
   wifiResolvedTarget = resolvedTarget
  }
  try output.start(settings);snapshot.effectiveAudio=settings.audio
  log("audio","outputStarted","purpose=\(settings.purpose.rawValue), output=\(settings.outputUID), session=\(id), rate=\(settings.audio.sampleRate), channels=\(settings.audio.channels), format=\(settings.audio.format.rawValue), source=\(settings.audio.source.rawValue), transport=\(settings.transport.rawValue)")
  let input = try output.makeInput()
  let delivery = AudioDelivery(input: input)
  audioDelivery = (id, delivery)
  let sessionToken = owned[.microphone]?.token ?? settings.pairingCode
  try receiver.start(settings:settings,session:settings.transport == .usb ? id:"wifi",expectedToken:sessionToken,onHandshake:{[weak self, input] clientAudio in
   input.updateSourceParameters(clientAudio)
   Task { @MainActor [weak self] in
    guard let self, self.valid(.microphone,id) else { return }
    self.snapshot.effectiveAudio = clientAudio
    self.log("audio","handshakeAccepted","session=\(id), transport=\(settings.transport.rawValue), clientRate=\(clientAudio.sampleRate), clientChannels=\(clientAudio.channels), clientFormat=\(clientAudio.format.rawValue)")
   }
  },onBatch:{[weak self, delivery] frames,acknowledge in
   defer {acknowledge()}
   do {
    if try delivery.consume(frames) {
     Task { @MainActor [weak self, delivery] in
      guard let update = delivery.takeUpdate(), let self,
            self.microphoneIntent != nil, self.valid(.microphone,id),
            self.audioRecovery == nil, !self.failingAudioSessions.contains(id) else { return }
      let isFirstBatch = (self.audioPacketCount == 0)
      self.audioPacketCount = update.packets
      self.audioWatchdog.frame(id,now:update.receivedAt)
      self.telemetry.update(level: update.level, waveform: update.waveform, receivedFrames: update.packets)
      if isFirstBatch || update.receivedAt - self.lastSnapshotTelemetryAt >= 1.0 {
       self.lastSnapshotTelemetryAt = update.receivedAt
       self.snapshot.level = update.level
       self.snapshot.waveform = update.waveform
       self.snapshot.receivedFrames = update.packets
      }
      if self.snapshot.audioState != .streaming {
       self.snapshot.audioState = .streaming
       self.log("audio","firstFrameReceived","session=\(id), transport=\(settings.transport.rawValue), packets=\(update.packets)")
      }
      if self.snapshot.microphone.phase != .running {
       self.status(.microphone,.running,self.phoneSilenced==true ? "手机麦克风被系统静音":"有效音频传输","实际PCM帧已到达；不等于已确认可听见声音")
      }
     }
    }
   } catch {
    let message = error.localizedDescription
    Task { @MainActor [weak self] in await self?.failAudio(id,message) }
   }
  },onError:{[weak self] message in Task{@MainActor in await self?.failAudio(id,message)}})
  snapshot.audioState = .handshake
  if let resolvedTarget = wifiResolvedTarget {
   let codeHint = settings.pairingCode.isEmpty ? "无需配对码（可留空）" : "已启用配对码校验"
   if resolvedTarget.isAmbiguous {
    let candidateList = resolvedTarget.candidates.map { "\($0.address) (\($0.name))" }.joined(separator: " / ")
    log("microphone", "wifiHostAmbiguous", "session=\(id), candidates=[\(resolvedTarget.candidates.map(\.name).joined(separator:","))], 检测到多个活动局域网地址，未自动同步至手机，等待用户明确选择")
    status(.microphone, .connecting, "存在多个局域网地址，请在设置中选择", "检测到多个活动局域网地址（\(candidateList)），无法判断手机所在网段；请在设置中选择「供手机连接的 Mac 地址」或在手机填写对应地址、端口 \(settings.audioPort)（\(codeHint)）")
    return
   }
   if !serial.isEmpty, let targetHost = resolvedTarget.host {
    do {
     let devices = ADB.devices(try await adb.run(nil, ["devices"], timeout: 4))
     adbServerWarm = true
     if devices.contains(where: { $0.0 == serial && $0.1 == "device" }) {
      try await prepareCompanion(.microphone, id, serial)
      let audio = settings.audio
      var args = ["shell", "am", "start", "-f", "0x18000000", "-n", Capabilities.androidControlComponent, "--es", "mode", "wifi", "--es", "session", "wifi", "--es", "wifiHost", targetHost, "--ez", "wifiHostExplicit", resolvedTarget.isUserSpecified ? "true" : "false", "--ei", "rate", String(audio.sampleRate), "--ei", "channels", String(audio.channels), "--ei", "format", audio.format.rawValue, "--es", "source", audio.source.rawValue, "--ei", "port", String(settings.audioPort), "--ei", "controlPort", String(settings.controlPort)]
      if !settings.pairingCode.isEmpty { args += ["--es", "token", settings.pairingCode] }
      _ = try await adb.run(serial, args, timeout: 4)
      log("microphone", "wifiPhoneSynced", "session=\(id), device=\(deviceAlias(serial)), explicitHost=\(resolvedTarget.isUserSpecified), port=\(settings.audioPort), 已通过USB向手机同步Wi-Fi目标地址与端口并请求启动")
     }
    } catch {
     log("microphone", "wifiPhoneSyncSkipped", "session=\(id), reason=\(error.localizedDescription)")
    }
   }
   if let targetHost = resolvedTarget.host {
    status(.microphone, .connecting, "等待Wi-Fi发送端", "请在手机填写 Mac 地址（\(targetHost)）、端口 \(settings.audioPort)（\(codeHint)）后开启 Wi-Fi 麦克风")
   } else {
    status(.microphone, .connecting, "等待Wi-Fi发送端（未检测到活动局域网接口）", "未检测到活动局域网 IPv4 接口；请连接局域网或在设置中填写 Mac 局域网地址，端口 \(settings.audioPort)（\(codeHint)）")
   }
   return
  }
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
  guard microphoneIntent != nil,valid(.microphone,id),audioRecovery==nil,let session=owned[.microphone],!failingAudioSessions.contains(id) else{return}
  let failureIntent=microphoneIntent
  failingAudioSessions.insert(id);defer{failingAudioSessions.remove(id)}
  log("audio","failure","session=\(id), frames=\(audioPacketCount), reason=\(message), \(output.diagnostics)")
  if let port=session.controlForward,let response=try? await ControlClient.request(port:port,body:["command":"status","session":id,"token":session.token]),response["cancelled"] as? Bool == true {
   guard valid(.microphone,id) else{return}
   revokeMicrophoneIntent("phoneStop")
   await stop(.microphone)
   if owned[.microphone]==nil {status(.microphone,.stopped,"手机已停止录音")}
   return
  }
  guard valid(.microphone,id) else{return}
  let recoverable = message.contains("INPUT_INTERRUPTED") || message.contains("FIRST_FRAME_TIMEOUT") || message.contains("HANDSHAKE_TIMEOUT")
  if recoverable, snapshot.settings.transport == .usb, let intent=microphoneIntent,
     microphoneIntentSerial==session.serial, audioRetryCount<3, !quitting {
   scheduleAudioRecovery(session, intent:intent, cause:message)
   return
  }
  if snapshot.settings.transport == .wifi,
     (recoverable || message.contains("HANDSHAKE_REJECTED")),
     microphoneIntent != nil, !quitting {
   audioWatchdog.begin(id)
   audioPacketCount = 0
   lastSnapshotTelemetryAt = 0
   snapshot.receivedFrames = 0
   snapshot.level = 0
   snapshot.waveform = []
   telemetry.reset()
   snapshot.audioState = .handshake
   renderProgressAt = ProcessInfo.processInfo.systemUptime
   log("audio","wifiDisconnected","session=\(id), reason=\(message), port=\(snapshot.settings.audioPort)")
   status(.microphone, .connecting, "等待Wi-Fi发送端", "上次Wi-Fi连接已断开（\(message)）；继续监听端口 \(snapshot.settings.audioPort) 等待手机重连")
   return
  }
  await stop(.microphone)
  guard failureIntent==microphoneIntent,owned[.microphone]==nil else{return}
  snapshot.audioState = .failed
  if owned[.microphone]==nil {status(.microphone,.failed,"音频失败",message,"AUDIO_FAILED")}
 }
 private func revokeMicrophoneIntent(_ reason:String) {
  microphoneIntent=nil;microphoneIntentSerial=nil;deferredNetworkResume=nil
  receiver.stop();output.stop();audioDelivery=nil
  telemetry.reset()
  audioRecovery?.cancel();audioRecovery=nil;audioRecoveryID=nil
  log("audio","intentEnded",reason)
 }
 private func intentIsCurrent(_ intent:UUID, serial:String) -> Bool {
  microphoneIntent==intent && microphoneIntentSerial==serial && snapshot.selectedDeviceID==serial && !quitting && !snapshot.isSavingSettings && !Task.isCancelled
 }
 private func resumeMicrophoneAfterNetwork() {
  guard let intent=deferredNetworkResume else{return}
  deferredNetworkResume=nil
  guard let serial=microphoneIntentSerial,intentIsCurrent(intent,serial:serial),owned[.microphone]==nil else{return}
  log("audio","networkResume","USB切换完成，恢复原录音意图")
  start(.microphone)
 }
 private func scheduleAudioRecovery(_ session:OwnedSession,intent:UUID,cause:String) {
  guard audioRecovery==nil else{return}
  let recoveryID=UUID();audioRecoveryID=recoveryID
  audioWatchdog.stop(session.id);receiver.stop();output.stop();audioDelivery=nil
  snapshot.audioState = .interrupted;snapshot.level=0;snapshot.waveform=[];telemetry.reset()
  status(.microphone,.connecting,"正在恢复音频连接",cause)
  audioRecovery=Task { [weak self] in
   guard let self else{return}
   defer {if self.audioRecoveryID==recoveryID {self.audioRecovery=nil;self.audioRecoveryID=nil}}
   // Never erase ownership or start a new recording before the old phone session
   // has authenticated its state and acknowledged cleanup.
   while self.audioRetryCount<3,self.intentIsCurrent(intent,serial:session.serial),self.owned[.microphone]?.id==session.id {
    self.audioRetryCount+=1
    let attempt=self.audioRetryCount
    do {
     try await Task.sleep(nanoseconds:UInt64(attempt)*1_000_000_000)
     guard self.intentIsCurrent(intent,serial:session.serial) else{return}
     let devices=ADB.devices(try await self.adb.run(nil,["devices"],timeout:3))
     guard self.intentIsCurrent(intent,serial:session.serial) else{return}
     guard devices.contains(where:{$0.0==session.serial && $0.1=="device"}) else{throw LinkError.failure("DEVICE_DISCONNECTED","原手机尚未恢复")}
     guard let port=session.controlForward,let target=session.controlTarget else{throw LinkError.failure("CONTROL_FORWARD","缺少原会话控制通道")}
     let mappings=try await self.adb.run(nil,["forward","--list"],timeout:3)
     guard self.intentIsCurrent(intent,serial:session.serial) else{return}
     if !ADB.ownsMapping(mappings,serial:session.serial,local:"tcp:\(port)",remote:"tcp:\(target)") {
      guard !mappings.split(separator:"\n").contains(where:{$0.split(whereSeparator:{$0.isWhitespace}).dropFirst().first==Substring("tcp:\(port)")}) else{throw LinkError.failure("OWNERSHIP_CHANGED","原控制端口已被占用")}
      let forwarding=Task {try await self.adb.run(session.serial,["forward","--no-rebind","tcp:\(port)","tcp:\(target)"],timeout:3)}
      self.audioForwardChange=(session.id,forwarding)
      do {_ = try await forwarding.value} catch {if self.audioForwardChange?.id==session.id {self.audioForwardChange=nil};throw error}
      if self.audioForwardChange?.id==session.id {self.audioForwardChange=nil}
     }
     guard self.intentIsCurrent(intent,serial:session.serial) else{return}
     let state=try await ControlClient.request(port:port,body:["command":"status","session":session.id,"token":session.token])
     guard self.intentIsCurrent(intent,serial:session.serial),self.owned[.microphone]?.id==session.id else{return}
     guard state["protocol"] as? Int==Capabilities.protocolVersion,state["session"] as? String==session.id else{throw LinkError.failure("PROTOCOL_MISMATCH","无法确认原手机会话，未重新录音")}
     guard state["cancelled"] as? Bool==false,state["accepted"] as? Bool==true,state["microphonePermission"] as? String=="allowed" else {
      self.revokeMicrophoneIntent("phoneStoppedOrPermissionRevoked")
      await self.stop(.microphone)
      return
     }
     self.log("audio","reconnectAttempt","attempt=\(attempt), session=\(session.id), phoneError=\(state["error"] as? String ?? "unknown")")
     await self.stop(.microphone)
     guard self.intentIsCurrent(intent,serial:session.serial),self.owned[.microphone]==nil else{return}
     await self.execute(.microphone)
     self.log("audio","reconnectResult","attempt=\(attempt), phase=\(self.snapshot.microphone.phase.rawValue); 等待有效PCM确认")
     return
    } catch is CancellationError {return}
    catch {
     guard self.intentIsCurrent(intent,serial:session.serial) else{return}
     self.log("audio","reconnectPending","attempt=\(attempt), reason=\(error.localizedDescription)")
    }
   }
   guard self.intentIsCurrent(intent,serial:session.serial) else{return}
   await self.stop(.microphone)
   if self.intentIsCurrent(intent,serial:session.serial),self.owned[.microphone]==nil {self.status(.microphone,.failed,"音频恢复未完成","已达本次录音的3次自动恢复上限，请检查连接后手动开始","AUDIO_RECOVERY_EXHAUSTED")}
  }
 }
 internal func observeOutput(_ id:String) async {
  guard valid(.microphone,id),audioRecovery==nil else{return}
  let now=ProcessInfo.processInfo.systemUptime
  let metrics=output.statistics
  if metrics.renderCallbacks != lastRenderCallbacks {
   lastRenderCallbacks=metrics.renderCallbacks;renderProgressAt=now;outputRestartCount=0
  } else if audioPacketCount>0,now-renderProgressAt>5 {
   if outputRestartCount<2 {
    outputRestartCount+=1
    do {
     try output.restartCurrentDevice(snapshot.settings)
     lastRenderCallbacks=output.statistics.renderCallbacks
     renderProgressAt=now
     log("audio","outputRestarted","session=\(id), attempt=\(outputRestartCount), output=\(snapshot.settings.outputUID), \(output.diagnostics)")
     return
    } catch {
     log("audio","outputRestartFailed","session=\(id), attempt=\(outputRestartCount), reason=\(error.localizedDescription)")
    }
   }
   await failAudio(id,"OUTPUT_STALLED: 输出设备超过5秒未消耗音频；未切换其他输出")
   return
  }
  let newLoss=metrics.droppedInputFrames>lastDroppedFrames || metrics.discardedBacklogFrames>lastBacklogFrames
  if newLoss,now-audioAnomalyAt>=5 {
   audioAnomalyAt=now;lastDroppedFrames=metrics.droppedInputFrames;lastBacklogFrames=metrics.discardedBacklogFrames
   log("audio","bufferRecovery","session=\(id), \(output.diagnostics), receiver={\(receiver.diagnostics)}")
  }
  if now-audioMetricsAt>=30 {
   audioMetricsAt=now
   log("audio","metrics","session=\(id), packets=\(audioPacketCount), silenced=\(phoneSilenced.map(String.init) ?? "unknown"), controlFailures=\(audioControlFailures), phone={\(phoneAudioDiagnostics)}, \(output.diagnostics), receiver={\(receiver.diagnostics)}, telemetry={\(telemetry.diagnostics)}")
  }
 }
 private func observePhoneAudio(_ id:String) async {
  let now=ProcessInfo.processInfo.systemUptime
  guard now-audioPollAt>=3,valid(.microphone,id),audioRecovery==nil else{return}
  audioPollAt=now
  do {
   let state=try await poll(.microphone,id)
   guard valid(.microphone,id),audioRecovery==nil else{return}
   audioControlFailures=0
   if let diagnostics=state["audioDiagnostics"] as? [String:Any] {
    let keys=["framesSent","pcmBytesSent","readFailures","transportFailures","captureFailures","silenceChanges","silencedMs","uptimeMs","readCalls","readDurationTotalUs","readDurationMaxUs","readGapCount","readGapTotalUs","readGapMaxUs","socketWriteCalls","socketWriteTotalUs","socketWriteMaxUs","socketWriteSlowCount","audioRecordLostFrames","audioRecordLostFramesApiAvailable","audioThreadPriorityApplied"]
    phoneAudioDiagnostics=keys.compactMap { key in
     guard let value=diagnostics[key] as? NSNumber else{return nil}
     return "\(key)=\(value.int64Value)"
    }.joined(separator:",")
   } else {phoneAudioDiagnostics="unknown"}
   if state["cancelled"] as? Bool==true {
    revokeMicrophoneIntent("phoneStop");await stop(.microphone);return
   }
   let silenced=state["silenced"] as? Bool
   if silenced != phoneSilenced {
    phoneSilenced=silenced
    log("audio","systemSilence","session=\(id), silenced=\(silenced.map(String.init) ?? "unknown")")
    if snapshot.microphone.phase == .running {
     status(.microphone,.running,silenced==true ? "手机麦克风被系统静音":"有效音频传输",silenced==true ? "连接仍在；请检查手机上占用录音的应用或系统麦克风开关":"实际PCM帧已到达；不等于已确认可听见声音")
    }
   }
  } catch {
   guard valid(.microphone,id),audioRecovery==nil else{return}
   audioControlFailures+=1
   if audioControlFailures==1 || audioControlFailures%10==0 {log("audio","controlObservationFailed","session=\(id), consecutive=\(audioControlFailures), reason=\(error.localizedDescription)")}
   // Missing telemetry alone must not terminate otherwise flowing audio.
  }
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
   deferredNetworkResume=microphoneIntent
   audioRecovery?.cancel();audioRecovery=nil;audioRecoveryID=nil
   await stop(.microphone)
   guard owned[.microphone]==nil else{throw LinkError.failure("AUDIO_CLEANUP_PENDING","USB重枚举前请先完成音频停止")}
   log("audio","usbReenumeration","USB共享切换需要重新识别；保留本次录音意图，网络准备后尝试恢复")
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
   resumeMicrophoneAfterNetwork()
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
       if ready {self.resumeMicrophoneAfterNetwork()}
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
  guard !quitting,!Task.isCancelled else{return}
  let now=ProcessInfo.processInfo.systemUptime
  let outputs=currentOutputs(forceRefresh:false)
  if let id=activeSessions[.microphone],valid(.microphone,id) {
   if snapshot.settings.outputUID != "default",!outputs.contains(where:{$0.id==snapshot.settings.outputUID}) {
    await failAudio(id,"OUTPUT_REMOVED: 指定输出离线，已停止，避免自动外放")
   }
  }
  if let id=activeSessions[.microphone],valid(.microphone,id),audioRecovery == nil {
   if let current=audioDelivery,current.id==id,let progress=current.delivery.progress() {
    audioPacketCount=progress.packets
    audioWatchdog.frame(id,now:progress.receivedAt)
   }
   if telemetry.receivedFrames != snapshot.receivedFrames || telemetry.level != snapshot.level {
    lastSnapshotTelemetryAt=now
    snapshot.level=telemetry.level
    snapshot.waveform=telemetry.waveform
    snapshot.receivedFrames=telemetry.receivedFrames
   }
   switch audioWatchdog.failure(id,now:now) {
   case .interrupted:await failAudio(id,"INPUT_INTERRUPTED: 超过3秒没有有效帧")
   case .firstFrame:await failAudio(id,"FIRST_FRAME_TIMEOUT: 获准开始采音后15秒未收到帧")
   case nil:break
   }
  }
  if let id=activeSessions[.microphone],valid(.microphone,id) {await observeOutput(id)}
  if let id=activeSessions[.microphone],valid(.microphone,id),snapshot.settings.transport == .usb {await observePhoneAudio(id)}
  if let s=owned[.macInternet],valid(.macInternet,s.id),snapshot.macInternet.phase == .running {
   do {
    let state=try await poll(.macInternet,s.id)
    if state["cancelled"] as? Bool == true {await stop(.macInternet);if owned[.macInternet]==nil {status(.macInternet,.stopped,"手机已停止VPN")};return}
    if state["network"] as? String != "connected" {throw LinkError.failure("NETWORK_LOST","手机VPN或USB转发通道已断开")}
    if now-networkHealthSummaryAt>=45 {
     networkHealthSummaryAt=now
     log("macInternet","healthSummary","session=\(s.id), phase=running, networkState=\(snapshot.networkState.rawValue), vpnPermission=\(snapshot.vpnPermission.rawValue)")
    }
   } catch {
    guard valid(.macInternet,s.id) else{return}
    await stop(.macInternet)
    if owned[.macInternet]==nil {status(.macInternet,.failed,"网络已中断",error.localizedDescription)}
   }
  } else if let s=owned[.phoneInternet],valid(.phoneInternet,s.id),snapshot.phoneInternet.phase == .running {
   if now-networkHealthSummaryAt>=45 {
    networkHealthSummaryAt=now
    log("phoneInternet","healthSummary","session=\(s.id), phase=running, interface=\(ncmInterface ?? "none"), networkState=\(snapshot.networkState.rawValue)")
   }
  }
 }
 private func cleanup(_ s:OwnedSession) async throws -> [String] {
  try checkCleanupAllowed()
  var failures=[String](),warnings=[String]()
  var cancellationAcknowledged=s.controlForward==nil
  if s.controlForward != nil {
   status(Workspace(rawValue:s.module) ?? .devices,.stopping,"取消手机任务","先停止本次任务，再恢复USB和网络服务")
   do{try await cancelPhone(s);cancellationAcknowledged=true}catch{failures.append(error.localizedDescription)}
  }
  try checkCleanupAllowed()
  if s.ncmBorrowed==true {log("phoneInternet","existingSharingPreserved","本次没有申请原usb0共享，停止不会关闭系统原共享")}
  if let change=ncmServiceChange,change.id==s.id {
   do{try await change.task.value}catch{log("phoneInternet","pendingServiceChange",error.localizedDescription)}
   ncmServiceChange=nil
  }
  try checkCleanupAllowed()
  // Restore the Mac service even if the phone has been unplugged. Only a
  // service this session enabled from Disabled is disabled again.
  for receipt in (s.ncmServices ?? []).reversed() {
   try checkCleanupAllowed()
   do{try await ncmServices().restore(receipt)}catch{failures.append(error.localizedDescription)}
  }
  if let change=ncmUSBChange,change.id==s.id {
   do{try await change.task.value}catch{log("phoneInternet","pendingUSBChange",error.localizedDescription)}
   ncmUSBChange=nil
  }
  try checkCleanupAllowed()
  if let pid=s.relayPID,let executable=s.relayExecutable {
   do {
    let process=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/ps"),["-p",String(pid),"-o","command="],timeout:2,cancellable:quitting)
    if process.code==0 {
     guard process.output.contains(executable),process.output.contains("-DUSBLinkMic.session=\(s.id)") else{throw LinkError.failure("PROCESS_OWNERSHIP_CHANGED","原PID已被其他进程使用，未终止")}
     kill(pid,SIGTERM)
     try? await Task.sleep(nanoseconds:300_000_000)
     let remaining=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/ps"),["-p",String(pid),"-o","command="],timeout:2,cancellable:quitting)
     if remaining.code==0,remaining.output.contains(executable),remaining.output.contains("-DUSBLinkMic.session=\(s.id)"){kill(pid,SIGKILL)}
    }
   }catch{failures.append(error.localizedDescription)}
  }
  try checkCleanupAllowed()
  if let functions=s.oldUSB {do{
   let driver=ncmDriver()
   try await driver.waitForDevice(s.serial,seconds:3,respectCancellation:quitting)
   try checkCleanupAllowed()
   var recoveryErrors=[String]()
   if s.ncmRequested==true {
    // The helper has a 30s process watchdog. Wait through its final receipt before
    // submitting stop; cancellation cannot leave a late start racing restoration.
    if let pending=s.ncmPendingStart {
     do{_ = try await driver.result(at:pending,serial:s.serial,session:s.id,respectCancellation:quitting)}
     catch{
      try checkCleanupAllowed()
      let processes=try await adb.run(s.serial,["shell","ps","-A","-o","ARGS"],timeout:4,cancellable:quitting)
      guard !processes.split(separator:"\n").contains(where:{$0.contains("com.zjx.usblinkmic.platform.NcmShellCommand") && $0.contains(s.id)}) else{throw LinkError.failure("NCM_START_PENDING","手机共享启动进程仍未结束，保留恢复记录")}
      log("phoneInternet","startReceiptMissing","启动进程已结束但回执不可读，仍执行停止与USB恢复")
     }
    }
    do {
     try checkCleanupAllowed()
     let path="/data/local/tmp/usblinkmic-\(s.id)-stop.json"
     try await driver.launch("stop",serial:s.serial,session:s.id,resultPath:path)
     try checkCleanupAllowed()
     let receipt=try await driver.result(at:path,serial:s.serial,session:s.id,respectCancellation:quitting)
     try NCMDriver.requireSuccess(receipt,action:"stop")
     try await driver.waitForTethering(serial:s.serial,session:s.id,active:false,respectCancellation:quitting)
    }catch{recoveryErrors.append(error.localizedDescription)}
   }
   try checkCleanupAllowed()
   do {
    let usb=try await driver.usbState(s.serial)
    log("phoneInternet","usbRestoreBaseline",usb.summary)
    guard let current=usb.active else{throw LinkError.failure("USB_STATE_UNKNOWN","无法读取恢复前的实际USB功能，保留恢复记录")}
    let active=NCMDriver.functions(current),original=NCMDriver.functions(functions)
    guard active==original || (active.contains("ncm") && active.subtracting(["ncm","adb"]).isEmpty) || (original==["none"] && !active.contains("ncm") && active.subtracting(["none","adb"]).isEmpty) else{throw LinkError.failure("USB_OWNERSHIP_CHANGED","用户或系统已改变USB功能，未覆盖后续更改")}
    if active != original {
     status(.phoneInternet,.stopping,"恢复USB模式","等待本次USB重枚举与实际功能确认")
     try await driver.setFunctions(functions,serial:s.serial,respectCancellation:quitting,reconnectSeconds:5,confirmationSeconds:5)
    } else {log("phoneInternet","usbAlreadyRestored","USB已是原值，未重复切换")}
   }catch{recoveryErrors.append(error.localizedDescription)}
   try checkCleanupAllowed()
   for path in recoveryErrors.isEmpty ? (s.ncmResults ?? []) : [] {
    try checkCleanupAllowed()
    do{try await driver.removeResult(path,serial:s.serial,session:s.id)}catch{recoveryErrors.append(error.localizedDescription)}
   }
   if !recoveryErrors.isEmpty {throw LinkError.failure("NCM_RECOVERY_INCOMPLETE",recoveryErrors.joined(separator:"；"))}
  }catch{failures.append(error.localizedDescription)}}
  try checkCleanupAllowed()
  if s.oldUSB != nil {
   do {
    let route=try await NetworkProbe.defaultInterface()
    if route != s.originalInterface {
     let warning="系统默认出口与开始时不同：原=\(s.originalInterface ?? "none")，当前=\(route ?? "none")；请检查系统网络设置"
     warnings.append(warning);log("phoneInternet","routeObservation",warning)
    }
   }catch {warnings.append("默认出口读取失败："+error.localizedDescription)}
  }
  try checkCleanupAllowed()
  if let port=s.controlForward {
   // Retain the control channel and journal until an authenticated cancellation
   // is acknowledged. An exit-zero `am start` is not a business receipt.
   if cancellationAcknowledged {
   do{
    let mappings=try await adb.run(nil,["forward","--list"],timeout:3,cancellable:quitting)
    let local="tcp:\(port)"
    if mappings.split(separator:"\n").contains(where:{$0.split(whereSeparator:{$0.isWhitespace}).contains(Substring(local))}) {
     guard let target=s.controlTarget,ADB.ownsMapping(mappings,serial:s.serial,local:local,remote:"tcp:\(target)") else{throw LinkError.failure("OWNERSHIP_CHANGED","控制转发归属已改变，未删除")}
     try checkCleanupAllowed()
     _ = try await adb.run(s.serial,["forward","--remove",local],timeout:3,cancellable:quitting)
    }
   }catch{failures.append(error.localizedDescription)}
   }
  }
  try checkCleanupAllowed()
  if let reverse=s.reverse {do{
   let mappings=try await adb.run(s.serial,["reverse","--list"],timeout:3,cancellable:quitting)
   let target=s.module==Workspace.macInternet.rawValue ? "tcp:48128":reverse
   let lines=mappings.split(separator:"\n").map{$0.split(whereSeparator:{$0.isWhitespace}).map(String.init)}
   if let match=lines.first(where:{$0.count>=3 && $0[1]==reverse}) {
    guard match[2]==target else{throw LinkError.failure("OWNERSHIP_CHANGED","USB反向映射已被修改，未删除")}
    try checkCleanupAllowed()
    _ = try await adb.run(s.serial,["reverse","--remove",reverse],timeout:3,cancellable:quitting)
   }
  }catch{failures.append(error.localizedDescription)}}
  if !failures.isEmpty {throw LinkError.failure("CLEANUP_INCOMPLETE",failures.joined(separator:"；"))}
  return warnings
 }
 private func cancelPhone(_ s:OwnedSession) async throws {
  try checkCleanupAllowed()
  guard let port=s.controlForward,let target=s.controlTarget,(1...65535).contains(port),(1...65535).contains(target) else{throw LinkError.failure("CONTROL_FORWARD","取消回执缺少有效控制端口")}
  let mappings=try await adb.run(nil,["forward","--list"],timeout:3,cancellable:quitting)
  try checkCleanupAllowed()
  let local="tcp:\(port)"
  if !ADB.ownsMapping(mappings,serial:s.serial,local:local,remote:"tcp:\(target)") {
   guard !mappings.split(separator:"\n").contains(where:{$0.split(whereSeparator:{$0.isWhitespace}).dropFirst().first==Substring(local)}) else{throw LinkError.failure("OWNERSHIP_CHANGED","取消控制端口已被其他会话使用，未覆盖")}
   _ = try await adb.run(s.serial,["forward","--no-rebind",local,"tcp:\(target)"],timeout:3,cancellable:quitting)
   try checkCleanupAllowed()
  }
  func acknowledged(_ response:[String:Any])->Bool {response["protocol"] as? Int==4 && response["session"] as? String==s.id && response["cancelAccepted"] as? Bool==true && response["producerStopped"] as? Bool==true}
  var accepted=false
  do {
   let response=try await ControlClient.request(port:port,body:["command":"stop","session":s.id,"token":s.token])
   accepted=response["session"] as? String==s.id && response["cancelAccepted"] as? Bool==true
   if acknowledged(response) {log(s.module,"cancelAcknowledged","取消已接受，生产者已停止；继续恢复资源");return}
  }
  catch {log(s.module,"cancelControlPending",error.localizedDescription)}
  try checkCleanupAllowed()
  if !accepted {
  let capabilities=try await adb.run(s.serial,["shell","content","call","--uri","content://com.zjx.usblinkmic.capabilities","--method","capabilities"],timeout:3,cancellable:quitting)
  try checkCleanupAllowed()
  let component=Self.compatibleCompanion(capabilities) ? Capabilities.androidControlComponent:(s.controlComponent ?? Capabilities.legacyAndroidControlComponent)
  let launch=try await adb.run(s.serial,["shell","am","start","-f","0x18000000","-n",component,"--es","mode","cancel","--es","session",s.id,"--es","token",s.token,"--ei","controlPort",String(target)],timeout:4,cancellable:quitting)
  try checkCleanupAllowed()
  log(s.module,"phoneCancelLaunch",launch)
  guard launch.range(of:#"Error:|Error type|SecurityException|Permission Denial|Exception occurred"#,options:[.regularExpression,.caseInsensitive])==nil else{throw LinkError.failure("CONTROL_CANCEL_REJECTED",launch)}
  }
  let deadline=ProcessInfo.processInfo.systemUptime+8
  repeat {
   try checkCleanupAllowed()
   do {if acknowledged(try await ControlClient.request(port:port,body:["command":"status","session":s.id,"token":s.token])) {log(s.module,"cancelAcknowledged","手机已确认本次取消");return}}
   catch {log(s.module,"cancelReceiptPending",error.localizedDescription)}
   try checkCleanupAllowed()
   try await Task.sleep(nanoseconds:300_000_000)
  }while ProcessInfo.processInfo.systemUptime<deadline
  throw LinkError.failure("STOP_NOT_ACKNOWLEDGED","手机未确认取消；保留控制通道与恢复记录，请重试停止")
 }
 public func stop(_ module:Workspace) async {
  await stop(module,source:.system)
 }
 public func stop(_ module:Workspace, source:ActionSource) async {
  guard !shutdownDeadlineExpired else{return}
  if recovering,let recovery=recoveryJob {await recovery.value}
  guard !shutdownDeadlineExpired else{return}
  if let job=stopJobs[module] {await job.value;return}
  jobs[module]?.cancel();jobs[module]=nil;jobIDs[module]=nil
  guard let session=owned[module] else{return}
  stopping.insert(module)
  // A separate, uncancelled cleanup task is shared by Stop, Save and Quit.
  // Keep ownership in the durable journal throughout every suspension point.
  let job=ProcessRunner.$currentGroup.withValue(processGroup) {
   Task {await finishStop(module,session,source:source)}
  }
  stopJobs[module]=job
  await job.value
 }
 private func finishStop(_ module:Workspace,_ session:OwnedSession, source:ActionSource = .system) async {
  let began=ProcessInfo.processInfo.systemUptime
  let wasActive=(activeSessions[module]==session.id)
  activeSessions[module]=nil
  if quitting {shutdownCleanupAttempted.insert(module)}
  defer{log(module.rawValue,"stopDuration","session=\(session.id), source=\(source.rawValue), elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-began))s, resourcesRemaining=\(owned[module] != nil)");stopping.remove(module);stopJobs[module]=nil}
  status(module,.stopping,"正在停止")
  if module == .microphone {
   if wasActive {
    log("audio","sessionEnd","session=\(session.id), packets=\(audioPacketCount), \(output.diagnostics), receiver={\(receiver.diagnostics)}, telemetry={\(telemetry.diagnostics)}")
   }
   receiver.stop();output.stop();audioDelivery=nil
   audioPacketCount=0;lastSnapshotTelemetryAt=0;lastRenderCallbacks=0;outputRestartCount=0;renderProgressAt=ProcessInfo.processInfo.systemUptime
   snapshot.level=0;snapshot.waveform=[];telemetry.reset();snapshot.audioState = .disconnected;audioWatchdog.stop(session.id);snapshot.receivedFrames=0;snapshot.effectiveAudio=nil
  }
  if module == .phoneInternet {
   ncmMonitor?.cancel();ncmMonitor=nil;ncmInterface=nil;snapshot.networkState = .stopped
   if session.oldUSB != nil,owned[.microphone] != nil,snapshot.settings.transport == .usb {deferredNetworkResume=microphoneIntent;audioRecovery?.cancel();audioRecovery=nil;audioRecoveryID=nil;await stop(.microphone,source:source)}
  }
  if module == .macInternet {relay?.terminationHandler=nil;if relay?.isRunning==true {relay?.terminate()};relay=nil;snapshot.networkState = .stopped}
  if module == .microphone,let forwarding=audioForwardChange,forwarding.id==session.id {_ = try? await forwarding.task.value;if audioForwardChange?.id==session.id {audioForwardChange=nil}}
  do {
   try checkCleanupAllowed()
   if module == .phoneInternet,session.oldUSB != nil,snapshot.settings.transport == .usb,owned[.microphone] != nil {throw LinkError.failure("AUDIO_CLEANUP_PENDING","麦克风停止尚未确认，保留USB模式与网络恢复记录，请重试停止")}
   if !recoveryBlocked {try saveJournal()}
   let warnings=try await cleanup(session)
   try checkCleanupAllowed()
   owned[module]=nil
   activeSessions[module]=nil
   if !recoveryBlocked {try saveJournal()}
   status(module,.stopped,"已停止",warnings.joined(separator:"；"))
   if module == .phoneInternet {resumeMicrophoneAfterNetwork()}
  } catch {
   owned[module]=session
   activeSessions[module]=nil
   if !recoveryBlocked {
    do{try saveJournal()}catch{log("recovery","journalSaveFailed",error.localizedDescription)}
   }
   if module == .microphone {
    if microphoneIntent != nil {revokeMicrophoneIntent("cleanupIncomplete")}
    snapshot.audioState = .failed
   } else {
    snapshot.networkState = .failed
   }
   status(module,.failed,"资源恢复待重试，请点击全部停止",error.localizedDescription,"CLEANUP_INCOMPLETE")
  }
 }
 public func stopAll() async {
  await stopAll(source:.system)
 }
 public func stopAll(source:ActionSource) async {
  revokeMicrophoneIntent("stopAll")
  for module in [Workspace.microphone,.phoneInternet,.macInternet] {
   await stop(module,source:source)
  }
 }
 public func shutdown(timeout:TimeInterval=8) async -> Bool {
  if let existing=shutdownTask {return await existing.value}
  let task=ProcessRunner.$currentGroup.withValue(processGroup) {
   Task {@MainActor in await performShutdown(timeout:timeout)}
  }
  shutdownTask=task
  return await task.value
 }
 private func performShutdown(timeout:TimeInterval) async -> Bool {
  quitting=true
  log("shutdown","started","timeout=\(String(format:"%.2f",timeout))s, owned=[\(owned.keys.map(\.rawValue).sorted().joined(separator:","))]")
  revokeMicrophoneIntent("shutdown")
  audioDeviceObserver?.stop();audioDeviceObserver=nil
  timer?.cancel();timer=nil
  deviceMonitor?.cancel();deviceMonitor=nil
  ncmMonitor?.cancel();ncmMonitor=nil
  for job in jobs.values {job.cancel()}
  jobs.removeAll();jobIDs.removeAll()
  audioForwardChange?.task.cancel();audioForwardChange=nil
  ncmServiceChange?.task.cancel()
  ncmUSBChange?.task.cancel()

  let effectiveTimeout=max(0.05,timeout)
  let cleanupTask=ProcessRunner.$currentGroup.withValue(processGroup) {
   Task {@MainActor in
    if self.recovering,let recovery=self.recoveryJob {
     await recovery.value
    }
    for module in [Workspace.microphone,.phoneInternet,.macInternet] {
     guard !self.shutdownDeadlineExpired else{break}
     if self.shutdownCleanupAttempted.contains(module),self.stopJobs[module]==nil {continue}
     await self.stop(module,source:.system)
    }
   }
  }

  let finishedInTime=await withCheckedContinuation { (continuation:CheckedContinuation<Bool,Never>) in
   var resumed=false
   let complete:@MainActor (Bool)->Void={ inTime in
    guard !resumed else{return}
    resumed=true
    continuation.resume(returning:inTime)
   }
   let deadlineTask=Task {@MainActor in
    try? await Task.sleep(nanoseconds:UInt64(effectiveTimeout*1_000_000_000))
    guard !Task.isCancelled else{return}
    complete(false)
   }
   Task {@MainActor in
    await cleanupTask.value
    deadlineTask.cancel()
    complete(true)
   }
  }

  if !finishedInTime {
   cleanupTask.cancel()
   forceTerminateAtDeadline()
   return true
  }

  if !owned.isEmpty {
   if !recoveryBlocked {
    do{try saveJournal()}catch{log("recovery","journalSaveFailed",error.localizedDescription)}
   }
   log("shutdown","incompleteCleanup","退出时仍有未完成清理的资源，已保留恢复记录供下次启动恢复")
  } else if recoveryBlocked {
   log("shutdown","recoveryBlocked","退出时保留现有恢复记录")
  } else {
   log("shutdown","completed","所有会话资源已清理完毕")
  }
  diagnosticsClosed=true;diagnosticLog.flush();return true
 }
 internal func forceTerminateAtDeadline() {
  guard !shutdownDeadlineExpired else {
   diagnosticsClosed=true
   diagnosticLog.flush()
   return
  }
  shutdownDeadlineExpired=true
  quitting=true
  activeSessions.removeAll()
  processGroup.cancelAll()
  audioDeviceObserver?.stop();audioDeviceObserver=nil
  timer?.cancel();timer=nil
  deviceMonitor?.cancel();deviceMonitor=nil
  ncmMonitor?.cancel();ncmMonitor=nil
  for job in jobs.values {job.cancel()}
  jobs.removeAll();jobIDs.removeAll()
  recoveryJob?.cancel()
  for job in stopJobs.values {job.cancel()}
  receiver.stop();output.stop();audioDelivery=nil;telemetry.reset()
  relay?.terminationHandler=nil
  if relay?.isRunning==true {relay?.terminate()}
  relay=nil
  for module in [Workspace.microphone,.phoneInternet,.macInternet] where owned[module] != nil {
   if module == .microphone {snapshot.audioState = .failed}else{snapshot.networkState = .failed}
   status(module,.failed,"资源恢复待重试，请点击全部停止","退出清理达到总期限，已保留恢复记录供下次启动恢复","CLEANUP_INCOMPLETE")
  }
  if !owned.isEmpty,!recoveryBlocked {
   do{try saveJournal()}catch{log("recovery","journalSaveFailed",error.localizedDescription)}
  }
  log("shutdown","deadlineReached","退出清理达到总期限，未完成资源已保留恢复记录")
  diagnosticsClosed=true
  diagnosticLog.flush()
 }
 private func exportLogs() {
  let panel=NSSavePanel();panel.nameFieldStringValue="USBLinkMic-diagnostics.txt"
  if panel.runModal() == .OK,let url=panel.url {do{let text=try diagnosticLog.exportText();try LogRedactor.redact(text).write(to:url,atomically:true,encoding:.utf8)}catch{log("logs","exportFailed",error.localizedDescription)}}
 }
}

@MainActor public final class TerminationCoordinator {
 private var terminating=false
 private var replied=false
 private var fallbackTask:Task<Void,Never>?

 public init() {}

 @discardableResult
 public func requestTermination(
  controller:SessionController?,
  shutdownTimeout:TimeInterval=8,
  fallbackTimeout:TimeInterval=9.5,
  reply:@escaping @MainActor (Bool)->Void
 ) -> NSApplication.TerminateReply {
  guard !terminating else{return .terminateLater}
  terminating=true
  replied=false

  let finish:@MainActor (Bool)->Void={ [weak self] shouldTerminate in
   guard let self,!self.replied else{return}
   self.replied=true
   self.fallbackTask?.cancel()
   self.fallbackTask=nil
   if !shouldTerminate {
    self.terminating=false
    self.replied=false
   }
   reply(shouldTerminate)
  }

  let effectiveFallback=max(0.05,fallbackTimeout)
  fallbackTask=Task {@MainActor in
   try? await Task.sleep(nanoseconds:UInt64(effectiveFallback*1_000_000_000))
   guard !Task.isCancelled else{return}
   controller?.forceTerminateAtDeadline()
   finish(true)
  }

  Task {@MainActor in
   let shouldTerminate=await controller?.shutdown(timeout:shutdownTimeout) ?? true
   finish(shouldTerminate)
  }

  return .terminateLater
 }
}
