package com.zjx.usblinkmic.platform
import android.app.*
import android.content.Context
import android.content.Intent
object Notifications {
 fun create(context: Context, title: String, stop: Intent): Notification {
  val manager=context.getSystemService(NotificationManager::class.java)
  manager.createNotificationChannel(NotificationChannel("linkmic", "USB LinkMic活动",NotificationManager.IMPORTANCE_LOW))
  val pending=PendingIntent.getService(context,title.hashCode(),stop,PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
  val open=PendingIntent.getActivity(context,0,Intent(context,com.zjx.usblinkmic.MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
  return Notification.Builder(context,"linkmic").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle(title).setContentText("点击应用查看状态；停止仅关闭本次会话").setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null,"停止",pending).build()).build()
 }
}
