package com.zjx.usblinkmic

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.zjx.usblinkmic.platform.Runtime

/** DUMP-protected ADB entry. The public launcher never trusts session extras. */
class AdbControlActivity : Activity() {
 override fun onCreate(savedInstanceState: Bundle?) {
  super.onCreate(savedInstanceState)
  if (savedInstanceState == null) {
   val ticket = Runtime.stageAdbCommand(intent)
   startActivity(Intent(this, MainActivity::class.java)
    .putExtra("controlTicket", ticket)
    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
  }
  finish()
 }
}
