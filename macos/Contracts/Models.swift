import Foundation

public enum Workspace: String, CaseIterable, Codable, Sendable { case microphone, phoneInternet, macInternet, devices, logs }
public enum TaskPhase: String, Codable, CaseIterable, Sendable { case stopped, checking, preparing, waitingUser, connecting, running, stopping, failed }
public enum PermissionState: String, Codable, Sendable { case notRequested, waiting, allowed, denied, settingsRequired }
public enum DeviceState: String, Codable, Sendable { case unauthorized, online, offline, reenumerating }
public enum AudioState: String, Codable, Sendable { case disconnected, handshake, waitingFrame, streaming, interrupted, failed }
public enum NetworkState: String, Codable, Sendable { case stopped, preparing, addressed, verifying, available, noInternet, unsupported, failed }
public enum AudioTransport: String, CaseIterable, Codable, Sendable { case usb, wifi }
public enum OutputPurpose: String, CaseIterable, Codable, Sendable { case monitor, virtualMicrophone }
public enum PCMFormat: String, CaseIterable, Codable, Sendable { case i16, f32 }
public enum RecordingSource: String, CaseIterable, Codable, Sendable { case microphone, unprocessed, voiceRecognition }
public struct AudioParameters: Codable, Equatable, Sendable {
 public var sampleRate: Int = 44100
 public var channels: Int = 1
 public var format: PCMFormat = .i16
 public var source: RecordingSource = .microphone
 public init() {}
}
public enum Capabilities {
 public static let protocolVersion = 4
 public static let runtimeRevision = 405
 public static let sampleRates = [16000, 44100, 48000, 96000]
 public static let channels = [1, 2]
 public static let maxFrameBytes = 262144
 public static let androidControlComponent = "com.zjx.usblinkmic/.AdbControlActivity"
 public static let legacyAndroidControlComponent = "com.zjx.usblinkmic/.MainActivity"
 public static let version = "4.0.5"
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
 public init() {}
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
public struct AppSnapshot: Sendable {
 public var devices: [Device] = []
 public var selectedDeviceID: String? = nil
 public var outputs: [OutputDevice] = []
 public var microphone = ModuleStatus()
 public var phoneInternet = ModuleStatus()
 public var macInternet = ModuleStatus()
 public var audioState: AudioState = .disconnected
 public var networkState: NetworkState = .stopped
 public var microphonePermission: PermissionState = .notRequested
 public var notificationPermission: PermissionState = .notRequested
 public var vpnPermission: PermissionState = .notRequested
 public var settings = Settings()
 public var isSavingSettings = false
 public var settingsMessage = ""
 public var logs: [LogEntry] = []
 public var level: Double = 0
 public var waveform: [Double] = []
 public var receivedFrames: UInt64 = 0
 public var effectiveAudio: AudioParameters? = nil
 public var wizardSkipped = false
 public var soundTestCompleted = false
 public var recoveryMessage = ""
 public init() {}
}
public enum UserAction: Sendable {
 case refresh, selectDevice(String), start(Workspace), stop(Workspace), stopAll
 case saveSettings(Settings), setGain(Double), setMuted(Bool), skipWizard, completeSoundTest
 case exportLogs, clearLogs, openDriverHelp, openPhoneSettings
}
@MainActor public protocol AppControlling: AnyObject {
 var snapshot: AppSnapshot { get }
 func send(_ action: UserAction)
}
