package com.zjx.usblinkmic.platform
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import com.zjx.usblinkmic.contracts.*
/** Read-only protocol discovery for adb shell; never requests permission or starts a service. */
class CapabilityProvider:ContentProvider() {
 override fun onCreate():Boolean {context?.let{Runtime.attach(it)};return true}
 override fun call(method:String,arg:String?,extras:Bundle?):Bundle {
  val uid=Binder.getCallingUid()
  check(uid==2000 || uid==android.os.Process.myUid() || uid==1000){"CAPABILITIES_READ_DENIED"}
  require(method=="capabilities"){"UNKNOWN_READ_METHOD"}
  return Bundle().apply {
   putInt("protocol",Capabilities.PROTOCOL_VERSION)
   putInt("controlRevision",Capabilities.CONTROL_REVISION)
   putInt("runtimeRevision",Capabilities.RUNTIME_REVISION)
   putString("version",Capabilities.VERSION)
   putString("controlComponent",Capabilities.CONTROL_COMPONENT)
   putString("sampleRates",Capabilities.SAMPLE_RATES.joinToString(","))
   putString("formats","i16,f32");putString("sources","microphone,unprocessed,voiceRecognition")
   putString("network","IPv4 TCP UDP; NCM ROM capability required")
  }
 }
 override fun query(uri:Uri,projection:Array<out String>?,selection:String?,selectionArgs:Array<out String>?,sortOrder:String?):Cursor?=null
 override fun getType(uri:Uri):String?=null
 override fun insert(uri:Uri,values:ContentValues?):Uri?=throw SecurityException("READ_ONLY")
 override fun delete(uri:Uri,selection:String?,selectionArgs:Array<out String>?):Int=throw SecurityException("READ_ONLY")
 override fun update(uri:Uri,values:ContentValues?,selection:String?,selectionArgs:Array<out String>?):Int=throw SecurityException("READ_ONLY")
}
