package com.sixpages.six_pages_voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * VoiceSessionService — keeps a live voice conversation alive when the screen sleeps.
 *
 * Two jobs, and they are different:
 *
 *  1. FOREGROUND SERVICE (with microphone type). On Android 14+, an app that is
 *     not in the foreground CANNOT hold the microphone unless it runs a foreground
 *     service typed `microphone`. Without this, Android silently mutes capture the
 *     moment the screen locks — the conversation would look alive and hear nothing.
 *
 *  2. PARTIAL WAKELOCK. Keeps the CPU running while allowing the SCREEN to sleep.
 *     PARTIAL_WAKE_LOCK is exactly that contract: screen off, CPU alive. We do NOT
 *     use SCREEN_BRIGHT/FULL wake locks — the user asked to be able to put the phone
 *     down, dark, and keep talking.
 *
 * The persistent notification is not a choice; Android requires one for any
 * foreground service. Wording matches the in-app button the user just pressed
 * ("Talk with Claude") so no new vocabulary is introduced mid-conversation.
 */
class VoiceSessionService : Service() {

    companion object {
        private const val TAG = "SixPagesVoice"
        private const val CHANNEL_ID = "six_pages_voice_session"
        private const val NOTIFICATION_ID = 8317

        // Wording locked with Amy: mirrors the "Talk with Claude" button.
        private const val NOTIF_TITLE = "Six Pages"
        private const val NOTIF_BODY = "Talking with Claude"

        fun start(context: Context) {
            val intent = Intent(context, VoiceSessionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VoiceSessionService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()

        val notification = buildNotification()

        // Android 10+ wants the service type declared at startForeground() too,
        // not only in the manifest. MICROPHONE is what legally permits background
        // mic capture on 14+.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        acquireWakeLock()
        Log.i(TAG, "VoiceSessionService started (foreground + partial wakelock)")

        // If Android kills us under memory pressure, do NOT silently resurrect a
        // dead conversation with no socket behind it. The session is owned by the
        // plugin; a zombie service would show a notification for a chat that is gone.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        Log.i(TAG, "VoiceSessionService stopped (wakelock released)")
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return

        // PARTIAL = CPU stays alive, SCREEN is allowed to sleep. That is the whole point.
        val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SixPages:VoiceSession")
        lock.setReferenceCounted(false)
        lock.acquire()
        wakeLock = lock
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                try {
                    it.release()
                } catch (e: Exception) {
                    Log.w(TAG, "Wakelock release failed: ${e.message}")
                }
            }
        }
        wakeLock = null
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        // LOW importance: shows in the tray, but makes NO sound, NO vibration, and
        // does NOT pop up. This is a presence indicator, not an interruption — and
        // Six Pages does not interrupt people.
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Voice conversation",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shown while a voice conversation is open."
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        // Tapping the notification returns the user to the app rather than doing nothing.
        val launchIntent = packageManager
            .getLaunchIntentForPackage(packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP }

        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE
        } else {
            android.app.PendingIntent.FLAG_UPDATE_CURRENT
        }

        val contentIntent = launchIntent?.let {
            android.app.PendingIntent.getActivity(this, 0, it, pendingFlags)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(NOTIF_TITLE)
            .setContentText(NOTIF_BODY)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)          // not swipe-dismissible while the chat is live
            .setContentIntent(contentIntent)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    setVisibility(Notification.VISIBILITY_PUBLIC)
                }
            }
            .build()
    }
}
