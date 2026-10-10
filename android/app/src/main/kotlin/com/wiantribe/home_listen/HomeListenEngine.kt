package com.wiantribe.home_listen

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the one Flutter engine, independently of any screen.
 *
 * Swiping the app away or pressing "Close all" destroys the Activity. A
 * FlutterActivity normally takes its engine down with it, which stopped the
 * microphone capture and the connection while the foreground service lingered.
 * Here the engine belongs to the process instead, so closing the screen leaves
 * the Dart code, the capture and the network connection running, held up by
 * the foreground service. Opening the app again simply shows that same
 * session.
 *
 * What this does not change: the "Microphone on" notification stays for as
 * long as the capture runs, with its Turn off button, and the notification and
 * the capture still end together. If Android kills the process, the service,
 * the engine and the microphone all go at once, so the notification can never
 * claim a microphone that is off.
 */
object HomeListenEngine {
    private const val ENGINE_ID = "home_listen_main"
    private const val CHANNEL = "com.wiantribe.home_listen/mic_service"
    const val REQUEST_NOTIFICATIONS = 4101
    const val REQUEST_EXPORT = 4102

    /** The visible screen, when there is one; permission prompts need it. */
    @Volatile var activity: Activity? = null

    private var pendingStart: (() -> Unit)? = null
    private var pendingExport: Pair<String, MethodChannel.Result>? = null

    fun engine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }

        val app = context.applicationContext
        val engine = FlutterEngine(app)
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        WebRtcPcmTap(engine.dartExecutor.binaryMessenger)

        // The notification's "Turn off" button asks Dart to close the microphone.
        MicMonitorService.onStopRequested = {
            Handler(Looper.getMainLooper()).post { channel.invokeMethod("stopRequested", null) }
        }
        channel.setMethodCallHandler { call, result -> handle(app, call, result) }

        // Handlers first, then Dart, so main() can call the channel at once.
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "exportActivity" -> {
                val screen = activity
                val content = call.argument<String>("content")
                if (screen == null || content == null || content.length > 1_000_000 || pendingExport != null) {
                    result.error("export_unavailable", "Open Home Listen and try exporting again.", null)
                } else {
                    pendingExport = Pair(content, result)
                    try {
                        screen.startActivityForResult(
                            Intent(Intent.ACTION_CREATE_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE)
                                .setType("application/json")
                                .putExtra(Intent.EXTRA_TITLE, "HomeListen-events.json"),
                            REQUEST_EXPORT,
                        )
                    } catch (_: Exception) {
                        pendingExport = null
                        result.error("export_unavailable", "This phone cannot open a file picker.", null)
                    }
                }
            }
            "openSpeechSession" -> {
                val screen = activity
                if (screen == null) result.error("session_unavailable", "Open Home Listen first.", null)
                else try {
                    screen.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://oralyvo.app/")))
                    result.success(true)
                } catch (_: Exception) {
                    result.error("session_unavailable", "Install a browser to open Oralyvo.", null)
                }
            }
            "configureFirebase" -> {
                context.getSharedPreferences("homelisten_firebase", Context.MODE_PRIVATE).edit()
                    .putString("appId", call.argument<String>("androidAppId"))
                    .putString("apiKey", call.argument<String>("apiKey"))
                    .putString("projectId", call.argument<String>("projectId"))
                    .putString("sender", call.argument<String>("messagingSenderId"))
                    .apply()
                result.success(null)
            }
            "start" -> startMonitor(context, call.argument<String>("text"), result, true)
            "startPlayback" -> startMonitor(context, call.argument<String>("text"), result, false)
            "update" -> {
                MicMonitorService.update(call.argument<String>("text") ?: "")
                result.success(null)
            }
            "stop" -> {
                context.stopService(Intent(context, MicMonitorService::class.java))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Raises the notification, answering true only once it can actually be seen.
     *
     * Android 13 and later hide a foreground service's notification until the
     * user grants POST_NOTIFICATIONS, and a user can also switch the app's
     * notifications off outright. Either way the monitor must not run, so the
     * answer is false and Dart declines to open the microphone.
     */
    private fun startMonitor(
        context: Context,
        text: String?,
        result: MethodChannel.Result,
        microphone: Boolean,
    ) {
        val begin = {
            val manager = context.getSystemService(NotificationManager::class.java)
            MicMonitorService.ensureChannel(context)
            val visibleChannel =
                manager.getNotificationChannel(MicMonitorService.CHANNEL_ID)?.importance !=
                    NotificationManager.IMPORTANCE_NONE
            if (!manager.areNotificationsEnabled() || !visibleChannel) {
                result.success(false)
            } else if (MicMonitorService.isAlive && MicMonitorService.currentMicrophone == microphone) {
                // Already up, e.g. a reconnect while the screen is closed.
                // Android refuses to start a service from the background, and
                // there is nothing to start: only the wording changes.
                MicMonitorService.update(text ?: "")
                result.success(true)
            } else {
                try {
                    context.startForegroundService(
                        Intent(context, MicMonitorService::class.java)
                            .putExtra(MicMonitorService.EXTRA_TEXT, text)
                            .putExtra(MicMonitorService.EXTRA_MICROPHONE, microphone),
                    )
                    result.success(true)
                } catch (_: SecurityException) {
                    result.error(
                        "monitor_permission",
                        "Open Home Listen and allow the required permissions to start monitoring.",
                        null,
                    )
                } catch (_: IllegalStateException) {
                    result.error("monitor_background", "Open Home Listen to restart monitoring.", null)
                }
            }
        }

        val needsAsk = Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        if (!needsAsk) {
            begin()
            return
        }
        val screen = activity
        if (screen == null) {
            // Nobody to show the prompt to, so the notification cannot be seen.
            result.success(false)
            return
        }
        pendingStart = begin
        screen.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    /** Called by the Activity with the answer to the notification prompt. */
    fun onPermissionResult(requestCode: Int) {
        if (requestCode != REQUEST_NOTIFICATIONS) return
        // Whatever the answer, areNotificationsEnabled() in the continuation is
        // the authority on whether the notification can be seen.
        pendingStart?.invoke()
        pendingStart = null
    }

    fun onActivityResult(context: Context, requestCode: Int, resultCode: Int, intent: Intent?) {
        if (requestCode != REQUEST_EXPORT) return
        val pending = pendingExport ?: return
        pendingExport = null
        val uri = intent?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.second.success(false)
            return
        }
        try {
            context.contentResolver.openOutputStream(uri)?.use { stream ->
                stream.write(pending.first.toByteArray(Charsets.UTF_8))
            } ?: throw IllegalStateException("No output stream")
            pending.second.success(true)
        } catch (_: Exception) {
            pending.second.error("export_failed", "Could not save event history to that location.", null)
        }
    }
}
