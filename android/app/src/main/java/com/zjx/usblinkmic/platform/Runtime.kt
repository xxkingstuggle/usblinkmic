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
 private val main by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }
 private var diagnosticFile: File? = null
 val bootId: String = UUID.randomUUID().toString().replace("-", "").take(8).lowercase()
 private val bootElapsedMs: Long = try { SystemClock.elapsedRealtime() } catch (_: Throwable) { 0L }
 private val rateLimitLastMs = ConcurrentHashMap<String, Long>()
 private val rateLimitSuppressed = ConcurrentHashMap<String, Int>()
 @Volatile private var audioUiVisible = false
 private data class PendingAudioMeter(val request: Request, val update: (AppSnapshot) -> AppSnapshot)
 private val audioMeterLock = Any()
 private var pendingAudioMeter: PendingAudioMeter? = null
 private var audioMeterDrainScheduled = false
 private val audioMeterDrain = Runnable { drainAudioMeter() }

 fun sessionAlias(session: String?): String {
  val raw = session?.trim().orEmpty()
  if (raw.isEmpty()) return "none"
  if (raw == "wifi") return "wifi"
  return raw.replace("-", "").take(8).lowercase()
 }

 private fun uptimeMs(): Long = try {
  (SystemClock.elapsedRealtime() - bootElapsedMs).coerceAtLeast(0L)
 } catch (_: Throwable) {
  0L
 }

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

 internal fun isCriticalLogRow(line: String): Boolean {
  return try {
   val row = JSONObject(line)
   val stage = row.optString("stage").lowercase()
   stage.contains("start") ||
    stage.contains("stop") ||
    stage.contains("fail") ||
    stage.contains("error") ||
    stage.contains("deny") ||
    stage.contains("denied") ||
    stage.contains("reject") ||
    stage.contains("cancel") ||
    stage.contains("handshake") ||
    stage.contains("settings") ||
    stage.contains("destroy") ||
    stage.contains("revoke")
  } catch (_: Exception) {
   false
  }
 }

 internal fun compactDiagnosticsLogLines(
  lines: List<String>,
  maxBytes: Int = 262144,
  targetBytes: Int = 196608
 ): List<String> {
  val clean = lines.map { it.trim() }.filter { it.isNotEmpty() }
  if (clean.isEmpty()) return emptyList()
  val budget = minOf(maxBytes, maxOf(targetBytes, 1024))
  val criticalBudget = maxOf(budget * 35 / 100, 256)
  val selectedIndices = mutableSetOf<Int>()
  var usedBytes = 0
  for (i in clean.indices.reversed()) {
   if (!isCriticalLogRow(clean[i])) continue
   val lineBytes = clean[i].toByteArray(Charsets.UTF_8).size + 1
   if (usedBytes + lineBytes > criticalBudget) break
   selectedIndices.add(i)
   usedBytes += lineBytes
  }
  for (i in clean.indices.reversed()) {
   if (selectedIndices.contains(i)) continue
   val lineBytes = clean[i].toByteArray(Charsets.UTF_8).size + 1
   if (usedBytes + lineBytes > budget) {
    if (selectedIndices.isEmpty() && i == clean.lastIndex && lineBytes <= maxBytes) {
     selectedIndices.add(i)
    }
    break
   }
   selectedIndices.add(i)
   usedBytes += lineBytes
  }
  return clean.indices.filter { selectedIndices.contains(it) }.map { clean[it] }
 }

 @Synchronized private fun persist(entry: LogEntry) {
  val file=diagnosticFile ?: return
  try {
   val row=JSONObject().put("timestamp",entry.timestamp).put("module",entry.module).put("stage",entry.stage).put("message",entry.message)
   val line = row.toString() + "\n"
   val lineBytes = line.toByteArray(Charsets.UTF_8).size
   if(file.exists() && file.length() + lineBytes > 262144) {
    val compacted = compactDiagnosticsLogLines(file.readLines() + row.toString(), maxBytes = 262144, targetBytes = 196608)
    val payload = if (compacted.isEmpty()) "" else compacted.joinToString("\n", postfix = "\n")
    file.writeText(payload, Charsets.UTF_8)
   } else {
    file.appendText(line, Charsets.UTF_8)
   }
  }catch(e:Exception){Log.e("USBLinkMic","diagnostics write failed: ${e.javaClass.simpleName}")}
 }

 @Synchronized fun exportRedactedLogs(): String {
  val entries = state.value.logs
  val header = "# USBLinkMic Android Diagnostics v=${Capabilities.VERSION} rev=${Capabilities.RUNTIME_REVISION} protocol=${Capabilities.PROTOCOL_VERSION} boot=$bootId entries=${entries.size}"
  if (entries.isEmpty()) return header
  val body = entries.joinToString("\n") { entry ->
   "${entry.timestamp} [${LogRedactor.redact(entry.module)}/${LogRedactor.redact(entry.stage)}] ${LogRedactor.redact(entry.message)}"
  }
  return "$header\n$body"
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
 fun log(
  module: String,
  stage: String,
  message: String,
  session: String? = null,
  source: String? = null,
  errorCode: String? = null,
  elapsedMs: Long? = null
 ) {
  var safe=message
  for(token in requests.values.map{it.token}+cancelledSessions.values) if(token.isNotEmpty())safe=safe.replace(token,"[REDACTED]")
  val activeSession = session ?: when (module) {
   "audio", "wifi", "microphone" -> audioRequest?.session
   "vpn", "macInternet" -> vpnRequest?.session
   else -> null
  }
  val meta = buildList {
   add("v=${Capabilities.VERSION}")
   add("rev=${Capabilities.RUNTIME_REVISION}")
   add("boot=$bootId")
   add("upMs=${uptimeMs()}")
   if (!activeSession.isNullOrBlank()) add("session=${sessionAlias(activeSession)}")
   if (!source.isNullOrBlank()) add("source=$source")
   if (!errorCode.isNullOrBlank()) add("code=$errorCode")
   if (elapsedMs != null) add("elapsedMs=$elapsedMs")
  }.joinToString(" ")
  safe=LogRedactor.redact("$meta | $safe").take(2048)
  val entry=LogEntry(module=module,stage=stage,message=safe)
  persist(entry)
  try { Log.i("USBLinkMic","$module/$stage: $safe") } catch (_: Throwable) {}
  update {it.copy(logs=(it.logs+entry).takeLast(500))}
 }

 fun logRateLimited(
  key: String,
  cooldownMs: Long = 10_000L,
  module: String,
  stage: String,
  message: String,
  session: String? = null,
  source: String? = null,
  errorCode: String? = null
 ) {
  val now = uptimeMs()
  val last = rateLimitLastMs[key]
  if (last != null && now - last < cooldownMs) {
   rateLimitSuppressed[key] = (rateLimitSuppressed[key] ?: 0) + 1
   return
  }
  val suppressed = rateLimitSuppressed.remove(key) ?: 0
  rateLimitLastMs[key] = now
  val decorated = if (suppressed > 0) "$message (suppressed=$suppressed)" else message
  log(module = module, stage = stage, message = decorated, session = session, source = source, errorCode = errorCode)
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
       if (command.optString("command") == "stop") { request.cancelled = true; stop(appContext, request, source = "macControl") }
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
    } catch (e: Exception) { logRateLimited(key = "control.requestFailed", module = "control", stage = "requestFailed", message = e.message ?: e.javaClass.simpleName) }
   }
  }
 }
 private fun permission(p: PermissionState) = when(p) { PermissionState.NOT_REQUESTED -> "notRequested"; PermissionState.WAITING -> "waiting"; PermissionState.ALLOWED -> "allowed"; PermissionState.DENIED -> "denied"; PermissionState.SETTINGS_REQUIRED -> "settingsRequired" }
 fun stop(context: Context, request: Request, source: String = "system") {
  request.cancelled = true
  log(request.mode, "stop", "停止会话 mode=${request.mode}", session = request.session, source = source)
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
   log("control", "invalidCommand", "会话标识或凭据格式无效", session = session, source = "adb", errorCode = "INVALID_COMMAND")
   return false
  }
  val previous = requests[session]
  if (previous != null && !java.security.MessageDigest.isEqual(previous.token.toByteArray(), token.toByteArray())) {
   log("control", "cancelRejected", "取消凭据与原会话不符", session = session, source = "adb", errorCode = "CANCEL_TOKEN_MISMATCH")
   return false
  }
  if (previous != null) stop(context, previous, source = "adbCancel")
  else cancelledSessions[session] = token
  try {
   beginControl(context, intent.getIntExtra("controlPort", 48125))
  } catch (e: Exception) {
   log("control", "cancelReceiptFailed", e.message ?: "控制通道不可用", session = session, source = "adb", errorCode = "CANCEL_RECEIPT_FAILED")
  }
  log("control", "cancelReceived", "已处理本次取消请求", session = session, source = "adb")
  return true
 }
 fun fail(request: Request, error: String, source: String = "runtime") {
  request.error = error
  val code = error.substringBefore(':').trim().takeIf { it.all { ch -> ch.isUpperCase() || ch == '_' || ch.isDigit() } } ?: "SESSION_FAILED"
  log(request.mode, "failed", error, session = request.session, source = source, errorCode = code)
  update { if (request.mode == "ncm") it.copy(phoneInternet=ModuleStatus(TaskPhase.FAILED,"共享失败",error,"NCM_FAILED")) else if (request.mode == "vpn") it.copy(macInternet = ModuleStatus(TaskPhase.FAILED,"供网失败",error,"NETWORK_FAILED")) else if(audioRequest === request || audioRequest == null || requests[request.session] === request) it.copy(microphone = ModuleStatus(TaskPhase.FAILED,"音频失败",error,"AUDIO_FAILED"), level=0.0,waveform=emptyList(),controlledByMac=false) else it }
 }
 fun source(p: AudioParameters) = when(p.source) { RecordingSource.MICROPHONE -> MediaRecorder.AudioSource.MIC; RecordingSource.UNPROCESSED -> MediaRecorder.AudioSource.UNPROCESSED; RecordingSource.VOICE_RECOGNITION -> MediaRecorder.AudioSource.VOICE_RECOGNITION }
}
