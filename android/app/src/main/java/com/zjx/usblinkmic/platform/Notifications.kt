package com.zjx.usblinkmic.platform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

object Notifications {
    private const val CHANNEL_ID = "linkmic"
    private const val ACCENT_BLUE = 0xFF0071E3.toInt()

    fun create(
        context: Context,
        title: String,
        stop: Intent,
        subtitle: String,
        subText: String? = null,
        stopLabel: String = "停止",
    ): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "USB LinkMic 实时传输服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "显示手机麦克风采音与 USB 供网前台常驻状态"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)

        val pendingStop = PendingIntent.getService(
            context,
            title.hashCode(),
            stop,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val openActivity = PendingIntent.getActivity(
            context,
            0,
            Intent(context, com.zjx.usblinkmic.MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setColor(ACCENT_BLUE)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setContentIntent(openActivity)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, stopLabel, pendingStop).build())
            .addAction(Notification.Action.Builder(null, "打开应用", openActivity).build())
        if (subText != null) builder.setSubText(subText)
        return builder.build()
    }
}
