package com.zjx.usblinkmic.contracts

enum class TaskPhase { STOPPED, CHECKING, PREPARING, WAITING_USER, CONNECTING, RUNNING, STOPPING, FAILED }
enum class PermissionState { NOT_REQUESTED, WAITING, ALLOWED, DENIED, SETTINGS_REQUIRED }
enum class PCMFormat { I16, F32 }
enum class RecordingSource { MICROPHONE, UNPROCESSED, VOICE_RECOGNITION }
data class AudioParameters(val sampleRate: Int = 44100, val channels: Int = 1, val format: PCMFormat = PCMFormat.I16, val source: RecordingSource = RecordingSource.MICROPHONE)
object Capabilities {
 const val PROTOCOL_VERSION = 4
 const val CONTROL_REVISION = 1
 const val RUNTIME_REVISION = 415
 const val CONTROL_COMPONENT = "com.zjx.usblinkmic/.AdbControlActivity"
 const val VERSION = "4.0.15"
 val SAMPLE_RATES = listOf(16000, 44100, 48000, 96000)
 val CHANNELS = listOf(1, 2)
 const val MAX_FRAME_BYTES = 262144
}
data class Settings(val schemaVersion: Int = 1, val audio: AudioParameters = AudioParameters(), val wifiHost: String = "", val audioPort: Int = 48124, val controlPort: Int = 48125, val pairingCode: String = "", val dns: String = "1.1.1.1", val routes: String = "0.0.0.0/0")
data class ModuleStatus(val phase: TaskPhase = TaskPhase.STOPPED, val stage: String = "已停止", val detail: String = "", val errorCode: String? = null)
data class LogEntry(val timestamp: Long = System.currentTimeMillis(), val module: String, val stage: String, val message: String)
data class AppSnapshot(
 val microphone: ModuleStatus = ModuleStatus(),
 val phoneInternet: ModuleStatus = ModuleStatus(),
 val macInternet: ModuleStatus = ModuleStatus(),
 val microphonePermission: PermissionState = PermissionState.NOT_REQUESTED,
 val notificationPermission: PermissionState = PermissionState.NOT_REQUESTED,
 val vpnPermission: PermissionState = PermissionState.NOT_REQUESTED,
 val settings: Settings = Settings(),
 val effectiveAudio: AudioParameters? = null,
 val level: Double = 0.0,
 val waveform: List<Double> = emptyList(),
 val frames: Long = 0,
 val controlledByMac: Boolean = false,
 val isSavingSettings: Boolean = false,
 val settingsMessage: String = "",
 val settingsError: String? = null,
 val settingsSavedRevision: Long = 0L,
 val logs: List<LogEntry> = emptyList()
)
sealed interface UserAction {
 data object StartWifi : UserAction
 data object StopAudio : UserAction
 data object StopVpn : UserAction
 data object Refresh : UserAction
 data object ClearLogs : UserAction
 data object ExportLogs : UserAction
 data class SaveSettings(val settings: Settings) : UserAction
 data object OpenSystemSettings : UserAction
}
