package com.ruachtech.counta

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
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
}
