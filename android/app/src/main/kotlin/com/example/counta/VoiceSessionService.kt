package com.ruachtech.counta

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps a voice session alive while the phone is locked or Counta is in the
 * background.
 *
 * Android only lets an app use the microphone in the background from a
 * foreground service of type `microphone`, and without one it stops the
 * capture and soon kills the app, which ends the session. This service does
 * no work of its own: the Flutter side keeps capturing and streaming as it
 * does in the foreground. It only holds the process at foreground priority,
 * shows the ongoing "counting" notification Android requires, and holds a
 * partial wake lock so the CPU keeps reading the microphone with the screen
 * off. It runs for exactly as long as the session does.
 */
class VoiceSessionService : Service() {
    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_COUNT = "count"
        const val DEFAULT_TITLE = "Voice counting is on"

        // Shared with the notification the Dart side shows on iOS, so the
        // name and description match NotificationService's.
        private const val CHANNEL_ID = "voice_session_channel"
        private const val NOTIFICATION_ID = 7301
        private const val WAKE_LOCK_TAG = "Counta:VoiceSession"

        /** Whether the service is in the foreground, so updates only go to one. */
        @Volatile
        private var running = false

        @Volatile
        private var tapIntent: PendingIntent? = null

        /**
         * Shows [count] on the running session's notification. Posting under
         * the service's own id replaces its notification in place, and the
         * service stays in the foreground. Nothing is posted when it isn't
         * running (a start Android refused), so no stray notification shows.
         */
        fun update(context: Context, title: String, count: Int) {
            if (!running) return
            val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(context, title, count))
        }

        private fun buildNotification(context: Context, title: String, count: Int): Notification =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_counta)
                .setContentTitle(title)
                .setContentText("$count so far · tap to return")
                .setContentIntent(tapIntent(context))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                // Android 16 Live Update: a status-bar chip showing the count
                // and a pinned card on the lock screen. Ignored before 16,
                // where this stays an ordinary ongoing notification.
                .setRequestPromotedOngoing(true)
                .setShortCriticalText(count.toString())
                .build()

        /** Built once: it never changes, and building it is a system call. */
        private fun tapIntent(context: Context): PendingIntent =
            tapIntent ?: PendingIntent.getActivity(
                context,
                0,
                context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ).also { tapIntent = it }

        /** Once per start: creating an existing channel changes nothing. */
        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            // Low, not min: Android never promotes a min-importance channel.
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Voice Session",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "Shown while voice counting is running" },
            )
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: DEFAULT_TITLE
        val count = intent?.getIntExtra(EXTRA_COUNT, 0) ?: 0
        ensureChannel(this)
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(this, title, count),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            // Refused (no microphone permission, or started from the
            // background on Android 14+). The session still counts while
            // Counta is open; it just cannot outlive a screen lock.
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        holdWakeLock()
        // Not sticky: if Android ever kills the process anyway, the session
        // is gone with it, and a service restarted with nothing to keep
        // alive would only show a misleading notification.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun holdWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            // Sessions run one to two hours. The cap only guards against a
            // stop that never arrives; the service releases it on stop.
            acquire(4 * 60 * 60 * 1000L)
        }
    }
}
