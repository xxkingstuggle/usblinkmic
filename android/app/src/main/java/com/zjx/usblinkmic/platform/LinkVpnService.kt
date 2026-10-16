package com.zjx.usblinkmic.platform

import android.content.Intent
import android.net.*
import android.os.*
import com.genymobile.gnirehtet.Forwarder
import com.genymobile.gnirehtet.RelayTunnelListener
import com.zjx.usblinkmic.contracts.*
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import kotlin.concurrent.thread

class LinkVpnService : VpnService() {
 private var tun:ParcelFileDescriptor?=null
 private var forwarder:Forwarder?=null
 private var request:Request?=null
 @Volatile private var closed=false
 @Volatile private var tunnelConnected=false
 override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
  if(intent?.action=="STOP"){request?.cancelled=true;stopSelf();return START_NOT_STICKY}
  val r=Runtime.vpnRequest
  if(r==null || r.cancelled || !r.accepted || intent?.getStringExtra("session")!=r.session || prepare(this)!=null){stopSelf();return START_NOT_STICKY}
  if(tun!=null) return START_NOT_STICKY
  request=r;closed=false
  startForeground(11,Notifications.create(this,"USB LinkMic反向供网",Intent(this,LinkVpnService::class.java).setAction("STOP")))
  try {
   val builder=Builder().setSession("USB LinkMic v4").addAddress("10.0.0.2",32).setMtu(16384).setBlocking(true)
   r.settings.dns.split(",").forEach{builder.addDnsServer(it.trim())}
   r.settings.routes.split(",").forEach { val parts=it.trim().split("/");builder.addRoute(parts[0],parts[1].toInt()) }
   tun=builder.establish() ?: error("VPN_ESTABLISH_DENIED")
   Runtime.update{it.copy(macInternet=ModuleStatus(TaskPhase.CONNECTING,"隧道已建立，验证实际请求"))}
   val handler=Handler(Looper.getMainLooper()){message ->
    if(!closed && Runtime.vpnRequest===r){
     tunnelConnected=message.what==0
     if(!tunnelConnected){Runtime.fail(r,"RELAY_DISCONNECTED: USB转发断开");stopSelf()}
    };true
   }
   forwarder=Forwarder(this,tun!!.fileDescriptor,RelayTunnelListener(handler));forwarder!!.forward()
   thread(name="linkmic-vpn-probe") {probeLoop(r)}
  }catch(e:Exception){Runtime.fail(r,e.message ?: "VPN_FAILED");stopSelf()}
  return START_NOT_STICKY
 }
 private fun probeLoop(r:Request) {
  val cm=getSystemService(ConnectivityManager::class.java)
  var startup=0
  while(!closed && !r.cancelled && Runtime.vpnRequest===r){
   try {
    val network=cm.allNetworks.firstOrNull { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN)==true }
    if(network==null || !tunnelConnected){check(startup++<15){"VPN_NETWORK_TIMEOUT"};Thread.sleep(1000);continue}
    val addresses=network.getAllByName("connectivitycheck.gstatic.com")
    check(addresses.isNotEmpty()){ "VPN_DNS_FAILED" }
    val connection=network.openConnection(URL("https://connectivitycheck.gstatic.com/generate_204")) as HttpsURLConnection
    try{connection.connectTimeout=8000;connection.readTimeout=8000;connection.instanceFollowRedirects=false;check(connection.responseCode==204){"VPN_HTTP_${connection.responseCode}"}}finally{connection.disconnect()}
    if(!closed && !r.cancelled)Runtime.update{it.copy(macInternet=ModuleStatus(TaskPhase.RUNNING,"手机DNS与HTTPS请求已通过VPN验证","IPv4 TCP/UDP；不承诺IPv6或ICMP"))}
    Thread.sleep(5000)
   }catch(e:Exception){if(!closed && !r.cancelled){Runtime.fail(r,"NO_UPSTREAM: ${e.message}");stopSelf()};return}
  }
 }
 override fun onRevoke(){request?.let{Runtime.fail(it,"VPN_REVOKED: 系统收回VPN授权")};stopSelf();super.onRevoke()}
 override fun onDestroy(){closed=true;try{forwarder?.stop()}catch(e:Exception){Runtime.log("vpn","cleanup",e.message ?: "转发关闭异常")};forwarder=null;try{tun?.close()}catch(e:Exception){Runtime.log("vpn","cleanup",e.message ?: "VPN关闭异常")};tun=null;request?.cancelled=true;if(Runtime.vpnRequest===request)Runtime.vpnRequest=null;Runtime.update{if(it.macInternet.phase==TaskPhase.FAILED)it else it.copy(macInternet=ModuleStatus())};super.onDestroy()}
}
