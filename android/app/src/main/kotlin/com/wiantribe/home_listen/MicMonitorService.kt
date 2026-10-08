package com.wiantribe.home_listen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * The visible half of "Listen to home".
 *
 * Capture itself runs in Dart; this service exists so that the microphone is
 * never open without a notification saying so, and so Android keeps the
 * process, the CPU and the Wi-Fi radio alive while the screen is off.
 *
 * It is deliberately plain. The notification goes up the instant the service
 * starts (FOREGROUND_SERVICE_IMMEDIATE, not the deferred default), it is
 * ongoing, public on the lock screen, and carries a "Turn off" button. There
 * is no code anywhere in this app that hides, delays, silences or disguises
 * it, and none should be added.
 */
class MicMonitorService : Service() {
    private var microphone = true
    private var wifiLock: WifiManager.WifiLock? = null
    private var cpuLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // The "Turn off" button. Tell Dart first so it closes the
            // microphone; the service then goes away with it.
            onStopRequested?.invoke()
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }

        val text = intent?.getStringExtra(EXTRA_TEXT) ?: DEFAULT_TEXT
        microphone = intent?.getBooleanExtra(EXTRA_MICROPHONE, true) ?: true
        ensureChannel(this)
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 29) {
            val type = if (microphone) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        instance = this
        currentMicrophone = microphone
        acquireLocks()
        // Not sticky. If the system kills this process the capture died with it,
        // and a restarted service would claim a microphone that is not on.
        return START_NOT_STICKY
    }

    // There is deliberately no onTaskRemoved. Closing the app from recents no
    // longer stops a session: the engine that runs it belongs to the process
    // (see HomeListenEngine), and this service keeps the process alive. The
    // notification and the Turn off button stay for as long as it runs.

    override fun onDestroy() {
        instance = null
        releaseLocks()
        super.onDestroy()
    }

    private fun stopForegroundAndSelf() {
        releaseLocks()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // The radio and CPU would otherwise idle within minutes of the screen going
    // off, which cuts the stream. Both are released with the service.
    private fun acquireLocks() {
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "HomeListen:monitor").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (cpuLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            cpuLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "HomeListen:monitor").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
        cpuLock?.takeIf { it.isHeld }?.release()
        cpuLock = null
    }

    private fun buildNotification(text: String): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, MicMonitorService::class.java).setAction(ACTION_STOP),
            flags,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_home_listen)
            .setContentTitle(if (microphone) "Home Listen • Microphone ON" else "Home Listen • Listening")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, if (microphone) "Turn off" else "Stop listening", stop).build())
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    /** Re-posts the notification with new wording, e.g. once a listener joins. */
    private fun refresh(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        const val ACTION_STOP = "com.wiantribe.home_listen.MIC_STOP"
        const val EXTRA_TEXT = "text"
        const val EXTRA_MICROPHONE = "microphone"
        private const val DEFAULT_TEXT = "Microphone on — streaming to your other device"
        const val CHANNEL_ID = "mic_monitor"
        private const val NOTIFICATION_ID = 41

        /** Set by MainActivity so a "Turn off" tap can reach the Dart side. */
        @Volatile var onStopRequested: (() -> Unit)? = null

        // Updating wording goes through the live instance rather than a fresh
        // startService, which Android refuses when the app is in the background.
        @Volatile private var instance: MicMonitorService? = null

        /** Whether the service is already up, so a reconnect need not start it. */
        val isAlive: Boolean get() = instance != null

        /** Which kind it was started as: capturing the microphone, or playing. */
        @Volatile var currentMicrophone = true

        fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(CHANNEL_ID, "Active monitoring", NotificationManager.IMPORTANCE_LOW)
            channel.description = "Visible while sharing a microphone or listening to home."
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            manager.createNotificationChannel(channel)
        }

        fun update(text: String) {
            instance?.refresh(text)
        }
    }
}
