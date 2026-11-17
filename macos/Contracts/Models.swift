import Combine
import Foundation

public enum Workspace: String, CaseIterable, Codable, Sendable { case microphone, phoneInternet, macInternet, devices, logs }
public enum TaskPhase: String, Codable, CaseIterable, Sendable { case stopped, checking, preparing, waitingUser, connecting, running, stopping, failed }
public enum PermissionState: String, Codable, Sendable { case notRequested, waiting, allowed, denied, settingsRequired }
public enum DeviceState: String, Codable, Sendable { case unauthorized, online, offline, reenumerating }
public enum AudioState: String, Codable, Sendable { case disconnected, handshake, waitingFrame, streaming, interrupted, failed }
public enum NetworkState: String, CaseIterable, Codable, Sendable { case stopped, preparing, addressed, verifying, available, noInternet, unsupported, failed }
public enum AudioTransport: String, CaseIterable, Codable, Sendable { case usb, wifi }
public enum OutputPurpose: String, CaseIterable, Codable, Sendable { case monitor, virtualMicrophone }
public enum PCMFormat: String, CaseIterable, Codable, Sendable { case i16, f32 }
public enum RecordingSource: String, CaseIterable, Codable, Sendable { case microphone, unprocessed, voiceRecognition }
public enum ActionSource: String, Codable, Sendable {
 case ui, menuBar, wizard, settings, phone, adb, system, recovery, test
}
public struct AudioParameters: Codable, Equatable, Sendable {
 public var sampleRate: Int = 44100
 public var channels: Int = 1
 public var format: PCMFormat = .i16
 public var source: RecordingSource = .microphone
 public init() {}
}
public enum Capabilities {
 public static let protocolVersion = 4
 public static let controlRevision = 1
 public static let runtimeRevision = 416
 public static let sampleRates = [16000, 44100, 48000, 96000]
 public static let channels = [1, 2]
 public static let maxFrameBytes = 262144
 public static let androidControlComponent = "com.zjx.usblinkmic/.AdbControlActivity"
 public static let legacyAndroidControlComponent = "com.zjx.usblinkmic/.MainActivity"
 public static let version = "4.0.17"
 public static let wifiRevision = 1
 public static let bonjourServiceType = "_usblinkmic._tcp"
}
public struct Settings: Codable, Equatable, Sendable {
 public var schemaVersion = 1
 public var audio = AudioParameters()
 public var transport: AudioTransport = .usb
 public var purpose: OutputPurpose = .monitor
 public var listenAddress = "127.0.0.1"
 public var audioPort = 48124
 public var controlPort = 48125
 public var wifiHost = ""
 public var pairingCode = ""
 public var outputUID = "default"
 public var gain: Double = 1
 public var muted = false
 public var dns = "1.1.1.1"
 public var routes = "0.0.0.0/0"
 /// Publishes this Mac on the local network and accepts trusted phones without a typed IP address.
 public var wifiAutoConnect = true
 public init() {}
 public init(from decoder: Decoder) throws {
  let c = try decoder.container(keyedBy: CodingKeys.self)
  schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
  audio = try c.decode(AudioParameters.self, forKey: .audio)
  transport = try c.decode(AudioTransport.self, forKey: .transport)
  purpose = try c.decode(OutputPurpose.self, forKey: .purpose)
  listenAddress = try c.decode(String.self, forKey: .listenAddress)
  audioPort = try c.decode(Int.self, forKey: .audioPort)
  controlPort = try c.decode(Int.self, forKey: .controlPort)
  wifiHost = try c.decode(String.self, forKey: .wifiHost)
  pairingCode = try c.decode(String.self, forKey: .pairingCode)
  outputUID = try c.decode(String.self, forKey: .outputUID)
  gain = try c.decode(Double.self, forKey: .gain)
  muted = try c.decode(Bool.self, forKey: .muted)
  dns = try c.decode(String.self, forKey: .dns)
  routes = try c.decode(String.self, forKey: .routes)
  // Added after the first schema-1 release: an older settings.json simply lacks it.
  wifiAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .wifiAutoConnect) ?? true
 }
}
public struct Device: Identifiable, Equatable, Sendable {
 public var id: String
 public var name: String
 public var state: DeviceState
 public init(id: String, name: String, state: DeviceState) { self.id=id; self.name=name; self.state=state }
}
public struct OutputDevice: Identifiable, Equatable, Sendable {
 public var id: String
 public var name: String
 public var isVirtual: Bool
 public init(id: String, name: String, isVirtual: Bool = false) { self.id=id; self.name=name; self.isVirtual=isVirtual }
}
public struct ModuleStatus: Equatable, Sendable {
 public var phase: TaskPhase = .stopped
 public var stage = "已停止"
 public var detail = ""
 public var errorCode: String? = nil
 public var taskID: String? = nil
 public init() {}
}
public struct LogEntry: Identifiable, Equatable, Sendable {
 public var id = UUID()
 public var date = Date()
 public var module: String
 public var stage: String
 public var message: String
 public init(module: String, stage: String, message: String) { self.module=module; self.stage=stage; self.message=message }
}
public struct TelemetryVisibilityState: Equatable, Sendable {
 public var hasWindow: Bool
 public var isViewHidden: Bool
 public var isWindowVisible: Bool
 public var isWindowUnoccluded: Bool
 public var isAppHidden: Bool

 public init(
  hasWindow: Bool,
  isViewHidden: Bool = false,
  isWindowVisible: Bool = true,
  isWindowUnoccluded: Bool = true,
  isAppHidden: Bool = false
 ) {
  self.hasWindow = hasWindow
  self.isViewHidden = isViewHidden
  self.isWindowVisible = isWindowVisible
  self.isWindowUnoccluded = isWindowUnoccluded
  self.isAppHidden = isAppHidden
 }

 public var isEffectivelyVisible: Bool {
  hasWindow && !isViewHidden && isWindowVisible && isWindowUnoccluded && !isAppHidden
 }
}

@MainActor public final class AudioTelemetry: ObservableObject {
 public private(set) var level: Double
 public private(set) var waveform: [Double]
 public private(set) var receivedFrames: UInt64
 public private(set) var publishCount: UInt64 = 0
 public private(set) var updateCount: UInt64 = 0
 private var registeredConsumers = Set<UUID>()
 private var consumerVisibility: [UUID: TelemetryVisibilityState] = [:]
 private var activeConsumers = Set<UUID>()

 public var hasActiveConsumers: Bool { !activeConsumers.isEmpty }
 public var activeConsumerCount: Int { activeConsumers.count }
 public var registeredConsumerCount: Int { registeredConsumers.count }

 public var diagnostics: String {
  "activeConsumers=\(activeConsumers.count), registeredConsumers=\(registeredConsumers.count), publishes=\(publishCount), updates=\(updateCount)"
 }

 public init(level: Double = 0, waveform: [Double] = [], receivedFrames: UInt64 = 0) {
  self.level = level
  self.waveform = waveform
  self.receivedFrames = receivedFrames
 }

 /// Registers a view consumer without overriding its native visibility state.
 /// Activation is controlled exclusively by `reportConsumerVisibility(_:state:)`.
 public func registerConsumer(_ id: UUID) {
  registeredConsumers.insert(id)
  if let state = consumerVisibility[id], state.isEffectivelyVisible {
   if activeConsumers.insert(id).inserted {
    publishCount &+= 1
    objectWillChange.send()
   }
  } else {
   activeConsumers.remove(id)
  }
 }

 /// Single source of truth for activating/deactivating a consumer from the native window/view visibility probe.
 public func reportConsumerVisibility(_ id: UUID, state: TelemetryVisibilityState) {
  registeredConsumers.insert(id)
  consumerVisibility[id] = state
  if state.isEffectivelyVisible {
   if activeConsumers.insert(id).inserted {
    publishCount &+= 1
    objectWillChange.send()
   }
  } else {
   activeConsumers.remove(id)
  }
 }

 /// Unregisters a destroyed or disappeared consumer and removes any active demand.
 public func unregisterConsumer(_ id: UUID) {
  registeredConsumers.remove(id)
  consumerVisibility.removeValue(forKey: id)
  activeConsumers.remove(id)
 }

 public func setConsumerActive(_ id: UUID, active: Bool) {
  if active {
   reportConsumerVisibility(id, state: TelemetryVisibilityState(hasWindow: true))
  } else {
   reportConsumerVisibility(id, state: TelemetryVisibilityState(hasWindow: false))
  }
 }

 public func update(level: Double, waveform: [Double], receivedFrames: UInt64) {
  let changed = self.level != level || self.waveform != waveform || self.receivedFrames != receivedFrames
  guard changed else { return }
  self.level = level
  self.waveform = waveform
  self.receivedFrames = receivedFrames
  updateCount &+= 1
  if hasActiveConsumers {
   publishCount &+= 1
   objectWillChange.send()
  }
 }

 public func reset() {
  let changed = self.level != 0 || !self.waveform.isEmpty || self.receivedFrames != 0
  self.level = 0
  self.waveform = []
  self.receivedFrames = 0
  if changed && hasActiveConsumers {
   publishCount &+= 1
   objectWillChange.send()
  }
 }
}
public enum WifiAutoPhase: String, Codable, Sendable { case off, starting, listening, pairing, preparing, streaming, paused, failed }
public struct WifiPairPrompt: Equatable, Sendable {
 public var requestID: String
 public var phoneName: String
 public var phoneShortID: String
 public var code: String
 public var expiresAt: Date
 public init(requestID: String, phoneName: String, phoneShortID: String, code: String, expiresAt: Date) {
  self.requestID=requestID; self.phoneName=phoneName; self.phoneShortID=phoneShortID; self.code=code; self.expiresAt=expiresAt
 }
}
public struct TrustedPhoneInfo: Identifiable, Equatable, Sendable {
 public var id: String
 public var name: String
 public var pairedAt: Date
 public init(id: String, name: String, pairedAt: Date) { self.id=id; self.name=name; self.pairedAt=pairedAt }
}
public struct WifiAutoSnapshot: Equatable, Sendable {
 public var phase: WifiAutoPhase = .off
 public var message = "Wi-Fi 自动连接已关闭"
 public var pendingPair: WifiPairPrompt? = nil
 public var trusted: [TrustedPhoneInfo] = []
 public var connectedPhoneName: String? = nil
 public var pausedByUser = false
 public init() {}
}
public struct USBChargingStatus: Equatable, Sendable {
 public enum Phase: String, Sendable {
  case disconnected, checking, requesting, charging, full, powered, notCharging
  case supplyingPower, unsupported, unknown, unconfirmed
 }
 public var phase: Phase
 public var batteryPercent: Int?
 public var canRequest: Bool
 public var deviceID: String?
 public init(_ phase: Phase = .disconnected, batteryPercent: Int? = nil, canRequest: Bool = false, deviceID: String? = nil) {
  self.phase=phase;self.batteryPercent=batteryPercent;self.canRequest=canRequest;self.deviceID=deviceID
 }
}
public struct AppSnapshot: Sendable {
 public var devices: [Device] = []
 public var selectedDeviceID: String? = nil
 public var outputs: [OutputDevice] = []
 public var microphone = ModuleStatus()
 public var phoneInternet = ModuleStatus()
 public var macInternet = ModuleStatus()
 public var audioState: AudioState = .disconnected
 public var networkState: NetworkState = .stopped
 public var usbCharging = USBChargingStatus()
 public var microphonePermission: PermissionState = .notRequested
 public var notificationPermission: PermissionState = .notRequested
 public var vpnPermission: PermissionState = .notRequested
 public var settings = Settings()
 public var lanCandidates: [String] = []
 public var isSavingSettings = false
 public var settingsMessage = ""
 public var settingsError: String? = nil
 public var settingsSavedRevision: UInt64 = 0
 public var logs: [LogEntry] = []
 public var level: Double = 0
 public var waveform: [Double] = []
 public var receivedFrames: UInt64 = 0
 public var effectiveAudio: AudioParameters? = nil
 public var wizardSkipped = false
 public var soundTestCompleted = false
 public var recoveryMessage = ""
 public var wifiAuto = WifiAutoSnapshot()
 public init() {}
}
public enum UserAction: Sendable {
 case refresh, selectDevice(String), start(Workspace), stop(Workspace), stopAll
 case observeUSBCharging(Bool), requestUSBCharging
 case saveSettings(Settings), setGain(Double), setMuted(Bool), skipWizard, completeSoundTest
 case exportLogs, clearLogs, openDriverHelp, openPhoneSettings
 case approveWifiPair(String), rejectWifiPair(String), forgetWifiPhone(String), setWifiAutoConnect(Bool)
}
@MainActor public protocol AppControlling: AnyObject {
 var snapshot: AppSnapshot { get }
 var telemetry: AudioTelemetry { get }
 func send(_ action: UserAction)
 func send(_ action: UserAction, source: ActionSource)
}
public extension AppControlling {
 var telemetry: AudioTelemetry {
  AudioTelemetry(level: snapshot.level, waveform: snapshot.waveform, receivedFrames: snapshot.receivedFrames)
 }
 func send(_ action: UserAction, source: ActionSource) {
  send(action)
 }
}
