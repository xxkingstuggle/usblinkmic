package com.zjx.usblinkmic.platform

import android.content.Context
import android.content.Intent
import android.media.AudioRecord
import android.media.AudioFormat
import android.media.MediaRecorder
import android.os.Build
import androidx.compose.runtime.mutableStateOf
import com.zjx.usblinkmic.contracts.*
import com.zjx.usblinkmic.support.*
import org.json.JSONObject
import android.util.Log
import java.io.File
import java.net.ServerSocket
import java.net.InetAddress
import java.util.UUID
import android.os.SystemClock
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

data class Request(val session: String, val token: String, val mode: String, val settings: Settings, @Volatile var cancelled: Boolean = false, @Volatile var accepted: Boolean = false, @Volatile var error: String = "")
object Runtime {
 val state = mutableStateOf(AppSnapshot())
 val requests = ConcurrentHashMap<String, Request>()
 val cancelledSessions = ConcurrentHashMap<String, String>()
 @Volatile var audioRequest: Request? = null
 @Volatile var vpnRequest: Request? = null
 private data class ControlLaunch(val intent: Intent, val created: Long)
 private val controlLaunches = LinkedHashMap<String, ControlLaunch>()
 @Synchronized fun stageAdbCommand(intent: Intent): String {
  val now=SystemClock.elapsedRealtime()
  controlLaunches.entries.removeAll { now-it.value.created>15000 }
  while(controlLaunches.size>=16) controlLaunches.remove(controlLaunches.keys.first())
  val ticket=UUID.randomUUID().toString()
  controlLaunches[ticket]=ControlLaunch(Intent(intent),now)
  return ticket
 }
 @Synchronized fun consumeAdbCommand(ticket: String): Intent? {
  val launch=controlLaunches.remove(ticket) ?: return null
  return launch.intent.takeIf { SystemClock.elapsedRealtime()-launch.created<=15000 }
 }
 private var server: ServerSocket? = null
 private val main = android.os.Handler(android.os.Looper.getMainLooper())
 private var diagnosticFile: File? = null
 @Volatile private var audioUiVisible = false
 private data class PendingAudioMeter(val request: Request, val update: (AppSnapshot) -> AppSnapshot)
 private val audioMeterLock = Any()
 private var pendingAudioMeter: PendingAudioMeter? = null
 private var audioMeterDrainScheduled = false
 private val audioMeterDrain = Runnable { drainAudioMeter() }
 @Synchronized fun attach(context: Context) {
  if(diagnosticFile!=null)return
  val file=File(context.applicationContext.filesDir,"diagnostics.jsonl")
  diagnosticFile=file
  try {
   if(file.isFile && file.length()<=262144) {
    val history=file.readLines().takeLast(500).mapNotNull {line -> try {
     val row=JSONObject(line)
     LogEntry(row.getLong("timestamp"),row.getString("module"),row.getString("stage"),LogRedactor.redact(row.getString("message")))
    }catch(_:Exception){null} }
    update {it.copy(logs=(history+it.logs).takeLast(500))}
   }
  }catch(e:Exception){Log.e("USBLinkMic","diagnostics load failed: ${e.javaClass.simpleName}")}
 }
 @Synchronized private fun persist(entry: LogEntry) {
  val file=diagnosticFile ?: return
  try {
   if(file.exists() && file.length()>196608) {
    val retained=file.readLines().takeLast(200).joinToString("\n",postfix="\n").toByteArray()
    file.writeBytes(retained.takeLast(131072).toByteArray())
   }
   val row=JSONObject().put("timestamp",entry.timestamp).put("module",entry.module).put("stage",entry.stage).put("message",entry.message)
   file.appendText(row.toString()+"\n")
  }catch(e:Exception){Log.e("USBLinkMic","diagnostics write failed: ${e.javaClass.simpleName}")}
 }
 @Synchronized fun clearLogs() {
  try {diagnosticFile?.writeText("");update {it.copy(logs=emptyList())}}
  catch(e:Exception){Log.e("USBLinkMic","diagnostics clear failed: ${e.javaClass.simpleName}")}
 }
 fun update(block: (AppSnapshot) -> AppSnapshot) { main.post { state.value = block(state.value) } }
 fun setAudioUiVisible(visible: Boolean) {
  audioUiVisible = visible
  if (!visible) synchronized(audioMeterLock) { pendingAudioMeter = null }
 }
 fun isAudioUiVisible(): Boolean = audioUiVisible
 fun updateAudio(request: Request, block: (AppSnapshot) -> AppSnapshot) {
  main.post { if(audioRequest === request && !request.cancelled) state.value = block(state.value) }
 }
 fun updateAudioMeter(request: Request, block: (AppSnapshot) -> AppSnapshot) {
  val shouldPost = synchronized(audioMeterLock) {
   if (!audioUiVisible || audioRequest !== request || request.cancelled) return
   pendingAudioMeter = PendingAudioMeter(request, block)
   if (audioMeterDrainScheduled) false else {
    audioMeterDrainScheduled = true
    true
   }
  }
  if (shouldPost && !main.post(audioMeterDrain)) {
   synchronized(audioMeterLock) {
    pendingAudioMeter = null
    audioMeterDrainScheduled = false
   }
  }
 }
 private fun drainAudioMeter() {
  val pending = synchronized(audioMeterLock) {
   pendingAudioMeter.also { pendingAudioMeter = null }
  }
  if (pending != null && audioUiVisible && audioRequest === pending.request && !pending.request.cancelled) {
   state.value = pending.update(state.value)
  }
  val shouldPostAgain = synchronized(audioMeterLock) {
   if (pendingAudioMeter == null) {
    audioMeterDrainScheduled = false
    false
   } else true
  }
  if (shouldPostAgain && !main.post(audioMeterDrain)) {
   synchronized(audioMeterLock) {
    pendingAudioMeter = null
    audioMeterDrainScheduled = false
   }
  }
 }
 fun log(module: String, stage: String, message: String) {
  var safe=message
  for(token in requests.values.map{it.token}+cancelledSessions.values) if(token.isNotEmpty())safe=safe.replace(token,"[REDACTED]")
  safe=LogRedactor.redact(safe).take(2048)
  val entry=LogEntry(module=module,stage=stage,message=safe)
  persist(entry)
  Log.i("USBLinkMic","$module/$stage: $safe")
  update {it.copy(logs=(it.logs+entry).takeLast(500))}
 }
 fun parametersSupported(p: AudioParameters): Boolean {
  val encoding = if (p.format == PCMFormat.I16) AudioFormat.ENCODING_PCM_16BIT else AudioFormat.ENCODING_PCM_FLOAT
  val channels = if (p.channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
  return p.sampleRate in Capabilities.SAMPLE_RATES && p.channels in Capabilities.CHANNELS && AudioRecord.getMinBufferSize(p.sampleRate, channels, encoding) > 0
 }
 fun beginControl(context: Context, port: Int) {
  val appContext=context.applicationContext
  if (server != null && server!!.localPort==port) return
  check(server==null || requests.values.none{it.accepted && !it.cancelled}) { "CONTROL_PORT_BUSY" }
  server?.close()
  server = ServerSocket(port, 8, InetAddress.getByName("127.0.0.1"))
  thread(name = "linkmic-control", isDaemon = true) {
   while (server?.isClosed == false) {
    try {
     val client = server!!.accept(); client.soTimeout = 3000
     client.use { socket ->
      val input = socket.getInputStream(); val bytes = ArrayList<Byte>()
      while (bytes.size <= 8192) { val b = input.read(); if (b < 0 || b == 10) break; bytes.add(b.toByte()) }
      require(bytes.size <= 8192) { "CONTROL_TOO_LARGE" }
      val command = JSONObject(bytes.toByteArray().toString(Charsets.UTF_8))
      val request = requests[command.optString("session")]
      val authorized = request != null && java.security.MessageDigest.isEqual(command.optString("token").toByteArray(), request.token.toByteArray())
      val tombstone=cancelledSessions[command.optString("session")]
      val cancelledBeforeStart=request==null && tombstone!=null && java.security.MessageDigest.isEqual(command.optString("token").toByteArray(),tombstone.toByteArray())
      val reply = if(command.optInt("controlRevision",-1)!=Capabilities.CONTROL_REVISION) JSONObject().put("error","CONTROL_REVISION_MISMATCH") else if(cancelledBeforeStart) JSONObject().put("protocol",4).put("session",command.optString("session")).put("cancelled",true).put("accepted",false).put("cancelAccepted",true).put("producerStopped",true).put("error","") else if (!authorized) JSONObject().put("error", "AUTH_REQUIRED") else {
       request!!
       val microphonePermission = if(request.mode=="audio" || request.mode=="wifi") {
        if(appContext.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)==android.content.pm.PackageManager.PERMISSION_GRANTED) PermissionState.ALLOWED
        else when(state.value.microphonePermission) {
         PermissionState.WAITING -> PermissionState.WAITING
         PermissionState.DENIED -> PermissionState.DENIED
         PermissionState.SETTINGS_REQUIRED -> PermissionState.SETTINGS_REQUIRED
         else -> PermissionState.DENIED
        }
       } else state.value.microphonePermission
       if(command.optString("command")=="ncmState" && request.mode=="ncm" && request.accepted && !request.cancelled) update { it.copy(phoneInternet=if(command.optString("network")=="connected") ModuleStatus(TaskPhase.RUNNING,"USB共享已连接") else ModuleStatus(TaskPhase.CONNECTING,"正在等待USB连接")) }
       if (command.optString("command") == "stop") { request.cancelled = true; stop(appContext, request) }
       val s = state.value
       val response = JSONObject().put("protocol", 4).put("session", request.session).put("cancelled", request.cancelled).put("cancelAccepted",request.cancelled).put("producerStopped",when(request.mode){"audio","wifi" -> !MicrophoneService.hasCapture(request);"vpn" -> vpnRequest !== request;else -> true}).put("error", request.error)
        .put("accepted",request.accepted).put("recording", MicrophoneService.isRecording(request))
        .put("microphonePermission", permission(microphonePermission)).put("notificationPermission", permission(s.notificationPermission)).put("vpnPermission", permission(s.vpnPermission))
        .put("network", when(s.macInternet.phase) { TaskPhase.RUNNING -> "connected"; TaskPhase.FAILED -> "failed"; else -> "preparing" })
       if(request.mode=="audio" || request.mode=="wifi") MicrophoneService.addStatusFields(response,request)
       response
      }
      reply.put("controlRevision",Capabilities.CONTROL_REVISION)
      socket.getOutputStream().write((reply.toString() + "\n").toByteArray())
     }
    } catch (e: Exception) { log("control", "requestFailed", e.message ?: e.javaClass.simpleName) }
   }
  }
 }
 private fun permission(p: PermissionState) = when(p) { PermissionState.NOT_REQUESTED -> "notRequested"; PermissionState.WAITING -> "waiting"; PermissionState.ALLOWED -> "allowed"; PermissionState.DENIED -> "denied"; PermissionState.SETTINGS_REQUIRED -> "settingsRequired" }
 fun stop(context: Context, request: Request) {
  request.cancelled = true
  update { when(request.mode){"ncm" -> it.copy(phoneInternet=ModuleStatus());"vpn" -> it.copy(macInternet=ModuleStatus());else -> if(audioRequest === request || audioRequest == null) it.copy(microphone=ModuleStatus(),level=0.0,waveform=emptyList(),controlledByMac=false) else it} }
  when(request.mode) {
   "audio", "wifi" -> if(audioRequest === request) { context.stopService(Intent(context, MicrophoneService::class.java)); MicrophoneService.stopCapture(request); audioRequest = null }
   "vpn" -> if(vpnRequest === request) context.stopService(Intent(context, LinkVpnService::class.java))
   "ncm" -> update { it.copy(phoneInternet=ModuleStatus()) }
  }
 }
 fun handleAdbCancel(context: Context, intent: Intent): Boolean {
  val session = intent.getStringExtra("session") ?: return false
  val token = intent.getStringExtra("token") ?: return false
  if (!token.matches(Regex("[a-fA-F0-9]{32}")) || session.isBlank() || session.length > 64) {
   log("control", "invalidCommand", "会话标识或凭据格式无效")
   return false
  }
  val previous = requests[session]
  if (previous != null && !java.security.MessageDigest.isEqual(previous.token.toByteArray(), token.toByteArray())) {
   log("control", "cancelRejected", "取消凭据与原会话不符")
   return false
  }
  if (previous != null) stop(context, previous)
  else cancelledSessions[session] = token
  try {
   beginControl(context, intent.getIntExtra("controlPort", 48125))
  } catch (e: Exception) {
   log("control", "cancelReceiptFailed", e.message ?: "控制通道不可用")
  }
  log("control", "cancelReceived", "已处理本次取消请求")
  return true
 }
 fun fail(request: Request, error: String) {
  request.error = error
  log(request.mode,"failed",error)
  update { if (request.mode == "ncm") it.copy(phoneInternet=ModuleStatus(TaskPhase.FAILED,"共享失败",error,"NCM_FAILED")) else if (request.mode == "vpn") it.copy(macInternet = ModuleStatus(TaskPhase.FAILED,"供网失败",error,"NETWORK_FAILED")) else if(audioRequest === request || audioRequest == null || requests[request.session] === request) it.copy(microphone = ModuleStatus(TaskPhase.FAILED,"音频失败",error,"AUDIO_FAILED"), level=0.0,waveform=emptyList(),controlledByMac=false) else it }
 }
 fun source(p: AudioParameters) = when(p.source) { RecordingSource.MICROPHONE -> MediaRecorder.AudioSource.MIC; RecordingSource.UNPROCESSED -> MediaRecorder.AudioSource.UNPROCESSED; RecordingSource.VOICE_RECOGNITION -> MediaRecorder.AudioSource.VOICE_RECOGNITION }
}
