package com.zjx.usblinkmic

import android.Manifest
import android.app.AlertDialog
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
import com.zjx.usblinkmic.contracts.*
import com.zjx.usblinkmic.platform.*
import com.zjx.usblinkmic.support.SettingsStore
import com.zjx.usblinkmic.support.SettingsValidator
import com.zjx.usblinkmic.ui.LinkMicScreen
import java.util.UUID

class MainActivity : ComponentActivity() {
 private var pending: Request? = null
 private var consentDialog: AlertDialog? = null
 private val microphonePermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
  val request = pending ?: return@registerForActivityResult
  Runtime.update { it.copy(microphonePermission = if(allowed) PermissionState.ALLOWED else if(shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) PermissionState.DENIED else PermissionState.SETTINGS_REQUIRED) }
  if (allowed && !request.cancelled) notificationThenStart(request) else Runtime.fail(request,"MICROPHONE_DENIED: 请允许录音权限，永久拒绝时到系统设置处理")
 }
 private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
  Runtime.update { it.copy(notificationPermission = if(allowed) PermissionState.ALLOWED else PermissionState.DENIED) }
  pending?.let { if(!it.cancelled) startAccepted(it) }
 }
 private val vpnPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
  val request = pending ?: return@registerForActivityResult
  if(result.resultCode == RESULT_OK && !request.cancelled) {Runtime.update { it.copy(vpnPermission = PermissionState.ALLOWED) }; notificationThenStart(request)}
  else {request.cancelled=true;Runtime.update { it.copy(vpnPermission = PermissionState.DENIED) };Runtime.fail(request,"VPN_DENIED: 用户取消VPN授权")}
 }
 override fun onCreate(savedInstanceState: Bundle?) {
  super.onCreate(savedInstanceState)
  try { Runtime.update { it.copy(settings=SettingsStore(this).load()) } } catch(e: Exception) { Runtime.log("settings","loadFailed",e.message ?: "配置无法读取") }
  setContent { LinkMicScreen(Runtime.state.value, ::action) }
  receive(intent)
 }
 override fun onNewIntent(intent: Intent) {super.onNewIntent(intent);setIntent(intent);receive(intent)}
 private fun receive(intent: Intent) {
  val mode=intent.getStringExtra("mode") ?: return
  val session=intent.getStringExtra("session") ?: return
  val token=intent.getStringExtra("token") ?: return
  if(!token.matches(Regex("[a-fA-F0-9]{32}")) || session.length>64) return
  if(mode=="cancel"){
   val previous=Runtime.requests[session]
   if(previous!=null && java.security.MessageDigest.isEqual(previous.token.toByteArray(),token.toByteArray()))Runtime.stop(this,previous)
   else if(previous==null)Runtime.cancelledSessions[session]=token
   return
  }
  if(mode !in listOf("audio","vpn","ncm") || Runtime.cancelledSessions[session]==token) return
  if(Runtime.requests.containsKey(session)) return
  val audio=AudioParameters(intent.getIntExtra("rate",44100),intent.getIntExtra("channels",1),if(intent.getStringExtra("format")=="f32")PCMFormat.F32 else PCMFormat.I16,when(intent.getStringExtra("source")){"unprocessed"->RecordingSource.UNPROCESSED;"voiceRecognition"->RecordingSource.VOICE_RECOGNITION;else->RecordingSource.MICROPHONE})
  val settings=Runtime.state.value.settings.copy(audio=audio,audioPort=intent.getIntExtra("port",48124),controlPort=intent.getIntExtra("controlPort",48125),pairingCode=token,dns=intent.getStringExtra("dns") ?: "1.1.1.1",routes=intent.getStringExtra("routes") ?: "0.0.0.0/0")
  val request=Request(session,token,mode,settings)
  Runtime.requests[session]=request
  if(pending?.let{!it.cancelled}==true){Runtime.fail(request,"USER_CONFIRMATION_BUSY: 请先处理当前手机确认");return}
  try {require(SettingsValidator.errors(settings).isEmpty());Runtime.beginControl(this,settings.controlPort)} catch(e:Exception){Runtime.fail(request,"CONTROL_CONFIG: ${e.message}");return}
  pending?.let { old -> if(!old.accepted) old.cancelled=true }
  consentDialog?.dismiss();pending=request
  Runtime.update { if(mode=="ncm") it.copy(phoneInternet=ModuleStatus(TaskPhase.WAITING_USER,"等待本次共享确认")) else if(mode=="vpn") it.copy(macInternet=ModuleStatus(TaskPhase.WAITING_USER,"等待本次供网确认")) else it.copy(microphone=ModuleStatus(TaskPhase.WAITING_USER,"等待本次录音确认"),controlledByMac=true) }
  consentDialog=AlertDialog.Builder(this).setTitle(if(mode=="audio") "允许本次Mac录音会话？" else "允许本次USB网络共享会话？")
   .setMessage("会话 ${session.take(8)}。请确认这是你刚在Mac发起的操作。应用不会在你确认前启动录音或VPN。")
   .setPositiveButton("继续") {_,_-> if(!request.cancelled){request.accepted=true;authorize(request)}}
   .setNegativeButton("取消") {_,_->request.cancelled=true;Runtime.fail(request,"USER_CANCELLED: 用户取消本次会话")}
   .setOnCancelListener{request.cancelled=true;Runtime.fail(request,"USER_CANCELLED")}.show()
 }
 private fun authorize(request: Request) {
  if(request.mode=="ncm") {
   pending=null
   Runtime.update{it.copy(phoneInternet=ModuleStatus(TaskPhase.PREPARING,"Mac正在配置本次USB共享","等待USB重枚举与系统共享回调；Mac实际请求验证后才显示可用"))}
   return
  }
  if(request.mode=="audio" || request.mode=="wifi") {
   if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){Runtime.update{it.copy(microphonePermission=PermissionState.WAITING)};microphonePermission.launch(Manifest.permission.RECORD_AUDIO)}
   else {Runtime.update{it.copy(microphonePermission=PermissionState.ALLOWED)};notificationThenStart(request)}
  } else {
   val intent=VpnService.prepare(this)
   if(intent!=null){Runtime.update{it.copy(vpnPermission=PermissionState.WAITING)};vpnPermission.launch(intent)}
   else{Runtime.update{it.copy(vpnPermission=PermissionState.ALLOWED)};notificationThenStart(request)}
  }
 }
 private fun notificationThenStart(request: Request) {
  pending=request
  if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED){Runtime.update{it.copy(notificationPermission=PermissionState.WAITING)};notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)}
  else{Runtime.update{it.copy(notificationPermission=PermissionState.ALLOWED)};startAccepted(request)}
 }
 private fun startAccepted(request: Request) {
  if(request.cancelled || !request.accepted) return
  pending=null
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
    val settings=Runtime.state.value.settings
    val errors=SettingsValidator.errors(settings)
    if(errors.isNotEmpty() || settings.wifiHost.isBlank() || !settings.pairingCode.matches(Regex("[a-fA-F0-9]{32}"))){Runtime.log("wifi","invalid",(errors+"填写Mac地址和32位配对码").joinToString("；"));return}
    val request=Request("wifi",settings.pairingCode,"wifi",settings,accepted=true);pending=request;authorize(request)
   }
   UserAction.StopAudio -> Runtime.audioRequest?.let{Runtime.stop(this,it)}
   UserAction.StopVpn -> Runtime.vpnRequest?.let{Runtime.stop(this,it)}
   UserAction.Refresh -> Runtime.log("status","refresh","状态来自当前服务，未自动启动任务")
   UserAction.ClearLogs -> Runtime.update{it.copy(logs=emptyList())}
   UserAction.OpenSystemSettings -> startActivity(Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:$packageName")))
   is UserAction.SaveSettings -> try {SettingsStore(this).save(action.settings);Runtime.audioRequest?.let{Runtime.stop(this,it)};Runtime.update{it.copy(settings=action.settings)} }catch(e: Exception){Runtime.log("settings","failed",e.message ?: "保存失败")}
  }
 }
 override fun onDestroy(){consentDialog?.dismiss();super.onDestroy()}
}
