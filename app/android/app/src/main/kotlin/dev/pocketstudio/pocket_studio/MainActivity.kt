// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0
package dev.pocketstudio.pocket_studio

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android shell for Pocket Studio: microphone permission and the recording
 * foreground service, via the "pocket_studio/platform" channel.
 * See wiki/components/audio-engine.md (Android) and wiki/features/record.md.
 */
class MainActivity : FlutterActivity() {
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "micPermission" -> result.success(micState())
                    "requestMicPermission" -> requestMic(result)
                    "startRecordingService" -> {
                        ContextCompat.startForegroundService(
                            this, Intent(this, RecordingService::class.java))
                        result.success(null)
                    }
                    "stopRecordingService" -> {
                        stopService(Intent(this, RecordingService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun granted() = ContextCompat.checkSelfPermission(
        this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun micState(): String = if (granted()) "granted" else "undetermined"

    private fun requestMic(result: MethodChannel.Result) {
        if (granted()) {
            result.success("granted")
            return
        }
        pendingPermission?.success(micState())
        pendingPermission = result
        ActivityCompat.requestPermissions(
            this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MIC)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_MIC) return
        val ok = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(if (ok) "granted" else "denied")
        pendingPermission = null
    }

    companion object {
        private const val CHANNEL = "pocket_studio/platform"
        private const val REQUEST_MIC = 4101
    }
}
