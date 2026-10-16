package com.zjx.usblinkmic

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.withResumed
import kotlinx.coroutines.launch
import com.zjx.usblinkmic.contracts.*
import com.zjx.usblinkmic.platform.*
import com.zjx.usblinkmic.support.SettingsStore
import com.zjx.usblinkmic.support.SettingsValidator
import com.zjx.usblinkmic.ui.LinkMicScreen

class MainActivity : ComponentActivity() {
 private var pending: Request? = null
 private val microphonePermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
  val request = pending ?: return@registerForActivityResult
  Runtime.update { it.copy(microphonePermission = if(allowed) PermissionState.ALLOWED else if(shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) PermissionState.DENIED else PermissionState.SETTINGS_REQUIRED) }
  if(request.cancelled) {pending=null;return@registerForActivityResult}
  if (allowed) notificationThenStart(request) else {pending=null;Runtime.fail(request,"MICROPHONE_DENIED: 请允许录音权限，永久拒绝时到系统设置处理")}
 }
 private val vpnPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
  val request = pending ?: return@registerForActivityResult
  if(request.cancelled) {pending=null;return@registerForActivityResult}
  if(result.resultCode == RESULT_OK) {Runtime.update { it.copy(vpnPermission = PermissionState.ALLOWED) }; notificationThenStart(request)}
  else {pending=null;request.cancelled=true;Runtime.update { it.copy(vpnPermission = PermissionState.DENIED) };Runtime.fail(request,"VPN_DENIED: 用户取消VPN授权")}
 }
 override fun onCreate(savedInstanceState: Bundle?) {
  super.onCreate(savedInstanceState)
  Runtime.attach(this)
  try { Runtime.update { it.copy(settings=SettingsStore(this).load()) } } catch(e: Exception) { Runtime.log("settings","loadFailed",e.message ?: "配置无法读取") }
  pending=savedInstanceState?.getString("pendingSession")?.let { Runtime.requests[it] }
  setContent { LinkMicScreen(Runtime.state.value, ::action) }
  receive(intent)
 }
 override fun onNewIntent(intent: Intent) {super.onNewIntent(intent);setIntent(intent);receive(intent)}
 override fun onSaveInstanceState(outState: Bundle) { pending?.let { outState.putString("pendingSession",it.session) };super.onSaveInstanceState(outState) }
 private fun whenResumed(request: Request, block: () -> Unit) {
  lifecycleScope.launch { lifecycle.withResumed {
   if(request.cancelled || request.error.isNotEmpty()) {if(pending===request) pending=null}
   else block()
  } }
 }
 private fun receive(launch: Intent) {
  val ticket=launch.getStringExtra("controlTicket") ?: return
  val intent=Runtime.consumeAdbCommand(ticket) ?: run {Runtime.log("control","ticketRejected","命令票据已消费、过期或随进程重启失效");return}
  Runtime.log("control","ticketConsumed","已消费受保护入口的一次性票据")
  val mode=intent.getStringExtra("mode") ?: return
  val session=intent.getStringExtra("session") ?: return
  val token=intent.getStringExtra("token") ?: return
  if(!token.matches(Regex("[a-fA-F0-9]{32}")) || session.isBlank() || session.length>64) {Runtime.log("control","invalidCommand","会话标识或凭据格式无效");return}
  if(mode=="cancel"){
   val previous=Runtime.requests[session]
   if(previous!=null && !java.security.MessageDigest.isEqual(previous.token.toByteArray(),token.toByteArray())){Runtime.log("control","cancelRejected","取消凭据与原会话不符");return}
   if(previous!=null && java.security.MessageDigest.isEqual(previous.token.toByteArray(),token.toByteArray()))Runtime.stop(this,previous)
   else if(previous==null)Runtime.cancelledSessions[session]=token
   try {Runtime.beginControl(this,intent.getIntExtra("controlPort",48125))}catch(e: Exception){Runtime.log("control","cancelReceiptFailed",e.message ?: "控制通道不可用")}
   Runtime.log("control","cancelReceived","已处理本次取消请求")
   return
  }
  if(mode !in listOf("audio","vpn","ncm") || Runtime.cancelledSessions[session]==token) return
  if(Runtime.requests.containsKey(session)) return
  val audio=AudioParameters(intent.getIntExtra("rate",44100),intent.getIntExtra("channels",1),if(intent.getStringExtra("format")=="f32")PCMFormat.F32 else PCMFormat.I16,when(intent.getStringExtra("source")){"unprocessed"->RecordingSource.UNPROCESSED;"voiceRecognition"->RecordingSource.VOICE_RECOGNITION;else->RecordingSource.MICROPHONE})
  val settings=Runtime.state.value.settings.copy(audio=audio,audioPort=intent.getIntExtra("port",48124),controlPort=intent.getIntExtra("controlPort",48125),pairingCode=token,dns=intent.getStringExtra("dns") ?: "1.1.1.1",routes=intent.getStringExtra("routes") ?: "0.0.0.0/0")
  val request=Request(session,token,mode,settings)
  Runtime.requests[session]=request
  if(mode!="ncm" && pending!=null){Runtime.fail(request,"SYSTEM_PERMISSION_BUSY: 请先完成当前Android系统权限处理");return}
  try {require(SettingsValidator.errors(settings).isEmpty());Runtime.beginControl(this,settings.controlPort)} catch(e:Exception){Runtime.fail(request,"CONTROL_CONFIG: ${e.message}");return}
  request.accepted=true
  Runtime.log(mode,"macStart","已接受Mac启动请求；不再要求应用内确认")
  Runtime.update { if(mode=="ncm") it.copy(phoneInternet=ModuleStatus(TaskPhase.PREPARING,"正在准备USB共享")) else if(mode=="vpn") it.copy(macInternet=ModuleStatus(TaskPhase.PREPARING,"正在准备供网")) else it.copy(microphone=ModuleStatus(TaskPhase.PREPARING,"正在准备录音"),controlledByMac=true) }
  if(mode=="ncm") authorize(request)
  else {pending=request;whenResumed(request) {authorize(request)}}
 }

 private fun authorize(request: Request) {
  if(request.mode=="ncm") {
   if(pending===request) pending=null
   Runtime.update{it.copy(phoneInternet=ModuleStatus(TaskPhase.PREPARING,"Mac正在配置本次USB共享","等待USB重枚举、系统共享回调及Mac接口地址"))}
   return
  }
  if(request.mode=="audio" || request.mode=="wifi") {
   if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){Runtime.update{it.copy(microphonePermission=PermissionState.WAITING,microphone=ModuleStatus(TaskPhase.WAITING_USER,"等待Android系统录音权限"))};microphonePermission.launch(Manifest.permission.RECORD_AUDIO)}
   else {Runtime.update{it.copy(microphonePermission=PermissionState.ALLOWED)};notificationThenStart(request)}
  } else {
   val intent=VpnService.prepare(this)
   if(intent!=null){Runtime.update{it.copy(vpnPermission=PermissionState.WAITING,macInternet=ModuleStatus(TaskPhase.WAITING_USER,"等待Android系统VPN权限"))};vpnPermission.launch(intent)}
   else{Runtime.update{it.copy(vpnPermission=PermissionState.ALLOWED)};notificationThenStart(request)}
  }
 }
 private fun notificationThenStart(request: Request) {
  // Notification permission is optional for foreground-service startup. Do not
  // add an unrelated approval step to a Mac start action; still post the required
  // foreground notification and expose the actual OS permission state.
  val allowed=Build.VERSION.SDK_INT<33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED
  Runtime.update { it.copy(notificationPermission=if(allowed) PermissionState.ALLOWED else PermissionState.DENIED) }
  whenResumed(request) {startAccepted(request)}
 }
 private fun startAccepted(request: Request) {
  if(request.cancelled || !request.accepted) {if(pending===request)pending=null;return}
  if(pending===request) pending=null
  val service=if(request.mode=="vpn") {
   if(Runtime.vpnRequest!=null){Runtime.fail(request,"VPN_BUSY: 请先停止现有VPN会话");return};Runtime.vpnRequest=request;LinkVpnService::class.java
  } else {
   if(!Runtime.parametersSupported(request.settings.audio)){Runtime.fail(request,"UNSUPPORTED_AUDIO: 设备不支持所选参数");return}
   if(Runtime.audioRequest!=null){Runtime.fail(request,"AUDIO_BUSY: 请先停止现有音频会话");return};Runtime.audioRequest=request;MicrophoneService::class.java
  }
  try { startForegroundService(Intent(this,service).putExtra("session",request.session)) } catch(e: Exception){if(Runtime.audioRequest===request)Runtime.audioRequest=null;if(Runtime.vpnRequest===request)Runtime.vpnRequest=null;Runtime.fail(request,"SERVICE_START: ${e.message}")}
 }
 private fun action(action: UserAction) {
  when(action){
   UserAction.StartWifi -> {
    if(pending!=null){Runtime.log("wifi","systemPermissionBusy","请先完成当前系统权限处理");return}
    val settings=Runtime.state.value.settings
    val errors=SettingsValidator.errors(settings)
    if(errors.isNotEmpty() || settings.wifiHost.isBlank() || !settings.pairingCode.matches(Regex("[a-fA-F0-9]{32}"))){Runtime.log("wifi","invalid",(errors+"填写Mac地址和32位配对码").joinToString("；"));return}
    val request=Request("wifi",settings.pairingCode,"wifi",settings,accepted=true);Runtime.requests[request.session]=request;pending=request;whenResumed(request){authorize(request)}
   }
   UserAction.StopAudio -> (Runtime.audioRequest ?: pending?.takeIf { it.mode=="audio" || it.mode=="wifi" })?.let{Runtime.stop(this,it)}
   UserAction.StopVpn -> (Runtime.vpnRequest ?: pending?.takeIf { it.mode=="vpn" })?.let{Runtime.stop(this,it)}
   UserAction.Refresh -> Runtime.log("status","refresh","状态来自当前服务，未自动启动任务")
   UserAction.ClearLogs -> Runtime.clearLogs()
   UserAction.OpenSystemSettings -> startActivity(Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:$packageName")))
   is UserAction.SaveSettings -> try {SettingsStore(this).save(action.settings);Runtime.audioRequest?.let{Runtime.stop(this,it)};Runtime.update{it.copy(settings=action.settings)} }catch(e: Exception){Runtime.log("settings","failed",e.message ?: "保存失败")}
  }
 }
}
