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
      val reply = if(cancelledBeforeStart) JSONObject().put("protocol",4).put("session",command.optString("session")).put("cancelled",true).put("accepted",false).put("error","") else if (!authorized) JSONObject().put("error", "AUTH_REQUIRED") else {
       request!!
       if(command.optString("command")=="ncmState" && request.mode=="ncm" && request.accepted && !request.cancelled && command.optString("network")=="available") update { it.copy(phoneInternet=ModuleStatus(TaskPhase.RUNNING,"Mac已验证USB出口实际请求")) }
       if (command.optString("command") == "stop") { request.cancelled = true; stop(context, request) }
       val s = state.value
       JSONObject().put("protocol", 4).put("session", request.session).put("cancelled", request.cancelled).put("error", request.error)
        .put("accepted",request.accepted).put("recording", audioRequest === request && MicrophoneService.recording)
        .put("microphonePermission", permission(s.microphonePermission)).put("notificationPermission", permission(s.notificationPermission)).put("vpnPermission", permission(s.vpnPermission))
        .put("network", when(s.macInternet.phase) { TaskPhase.RUNNING -> "available"; TaskPhase.FAILED -> "noInternet"; else -> "preparing" })
      }
      socket.getOutputStream().write((reply.toString() + "\n").toByteArray())
     }
    } catch (e: Exception) { log("control", "requestFailed", e.message ?: e.javaClass.simpleName) }
   }
  }
 }
 private fun permission(p: PermissionState) = when(p) { PermissionState.NOT_REQUESTED -> "notRequested"; PermissionState.WAITING -> "waiting"; PermissionState.ALLOWED -> "allowed"; PermissionState.DENIED -> "denied"; PermissionState.SETTINGS_REQUIRED -> "settingsRequired" }
 fun stop(context: Context, request: Request) {
  request.cancelled = true
  update { when(request.mode){"ncm" -> it.copy(phoneInternet=ModuleStatus());"vpn" -> it.copy(macInternet=ModuleStatus());else -> it.copy(microphone=ModuleStatus(),level=0.0,waveform=emptyList(),controlledByMac=false)} }
  when(request.mode) {
   "audio", "wifi" -> if(audioRequest === request) { context.stopService(Intent(context, MicrophoneService::class.java)); MicrophoneService.stopCapture() }
   "vpn" -> if(vpnRequest === request) context.stopService(Intent(context, LinkVpnService::class.java))
   "ncm" -> update { it.copy(phoneInternet=ModuleStatus()) }
  }
 }
 fun fail(request: Request, error: String) {
  request.error = error
  log(request.mode,"failed",error)
  update { if (request.mode == "ncm") it.copy(phoneInternet=ModuleStatus(TaskPhase.FAILED,"共享失败",error,"NCM_FAILED")) else if (request.mode == "vpn") it.copy(macInternet = ModuleStatus(TaskPhase.FAILED,"供网失败",error,"NETWORK_FAILED")) else it.copy(microphone = ModuleStatus(TaskPhase.FAILED,"音频失败",error,"AUDIO_FAILED"), level=0.0,waveform=emptyList()) }
 }
 fun source(p: AudioParameters) = when(p.source) { RecordingSource.MICROPHONE -> MediaRecorder.AudioSource.MIC; RecordingSource.UNPROCESSED -> MediaRecorder.AudioSource.UNPROCESSED; RecordingSource.VOICE_RECOGNITION -> MediaRecorder.AudioSource.VOICE_RECOGNITION }
}
