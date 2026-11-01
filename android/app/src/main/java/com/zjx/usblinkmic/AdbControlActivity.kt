package com.zjx.usblinkmic

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.zjx.usblinkmic.platform.Runtime

/** DUMP-protected ADB entry. The public launcher never trusts session extras. */
class AdbControlActivity : Activity() {
 override fun onCreate(savedInstanceState: Bundle?) {
  super.onCreate(savedInstanceState)
  forward(intent)
 }
 override fun onNewIntent(intent: Intent) {
  super.onNewIntent(intent)
  setIntent(intent)
  forward(intent)
 }
 private fun forward(command: Intent) {
  Runtime.attach(this)
  val mode=command.getStringExtra("mode")?.takeIf{it in listOf("audio","vpn","ncm","wifi","cancel")} ?: "invalid"
  Runtime.log("control","entryReceived","受保护命令入口已执行；mode=$mode")
  try {
   if (mode == "cancel" && Runtime.handleAdbCancel(this, command)) {
    Runtime.log("control","cancelHandledDirect","已在受保护命令入口直接完成取消与回执准备")
    return
   }
   val ticket = Runtime.stageAdbCommand(command)
   // The transient control task must never become the public launcher's task identity.
   startActivity(Intent(this, MainActivity::class.java)
    .putExtra("controlTicket", ticket)
    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
   Runtime.log("control","ticketForwarded","命令已转交主界面")
  } catch(e: Exception) {
   Runtime.log("control","entryFailed",e.message ?: e.javaClass.simpleName)
  } finally {finish()}
 }
}
