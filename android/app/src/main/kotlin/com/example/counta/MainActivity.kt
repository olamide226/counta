package com.ruachtech.counta

import android.Manifest
import android.content.Intent
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.ruachtech.counta/voice_session",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(
                    startVoiceSession(call.argument<String>("title"), call.argument<Int>("count")),
                )
                "update" -> {
                    VoiceSessionService.update(
                        this,
                        call.argument<String>("title") ?: "Voice counting is on",
                        call.argument<Int>("count") ?: 0,
                    )
                    result.success(null)
                }
                "liveUpdates" -> result.success(liveUpdatesState())
                "openLiveUpdatesSettings" -> result.success(openLiveUpdatesSettings())
                "stop" -> {
                    stopService(Intent(this, VoiceSessionService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Answers whether the service was asked to start. A microphone service
     * needs the permission already granted, so this declines until it is and
     * the Dart side asks again on the next status change.
     */
    private fun startVoiceSession(title: String?, count: Int?): Boolean {
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) return false
        val intent = Intent(this, VoiceSessionService::class.java)
            .putExtra(VoiceSessionService.EXTRA_TITLE, title)
            .apply { if (count != null) putExtra(VoiceSessionService.EXTRA_COUNT, count) }
        return try {
            ContextCompat.startForegroundService(this, intent)
            true
        } catch (e: Exception) {
            // Android 12+ refuses a start from the background.
            false
        }
    }

    /**
     * Whether Counta's counting notification can be a Live Update (Android
     * 16+): "on", "off" (the user's per-app switch is off), or "unsupported".
     * There is no permission dialog for it, only that switch.
     */
    private fun liveUpdatesState(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) return "unsupported"
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        // canPostPromotedNotifications() reads only the Live Updates switch:
        // it says yes for an app whose notifications are blocked outright.
        return if (manager.areNotificationsEnabled() && manager.canPostPromotedNotifications()) "on" else "off"
    }

    /** Opens the Live Updates switch for Counta, else its notification settings. */
    private fun openLiveUpdatesSettings(): Boolean {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val intents = buildList {
            // Blocked notifications are fixed on the app's notification page;
            // the Live Updates page cannot help until they are allowed.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA && manager.areNotificationsEnabled()) {
                add(Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS))
            }
            add(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS))
        }
        for (intent in intents) {
            try {
                startActivity(intent.putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                return true
            } catch (e: Exception) {
                // Not on this phone: try the next page.
            }
        }
        return false
    }
}
