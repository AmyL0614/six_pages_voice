package com.sixpages.six_pages_voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.telecom.DisconnectCause
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallsManager
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select

/**
 * VoiceSessionService — foreground host for a live voice conversation, AND (on
 * API 26+) the owner of the Android Telecom call that represents that conversation.
 *
 * ───────────────────────────────────────────────────────────────────────────
 * BUILD 2A — TELECOM CALL LIFECYCLE ONLY. ROUTING NOT YET MIGRATED.
 * ───────────────────────────────────────────────────────────────────────────
 * This build stands up the Core-Telecom call and PROVES it can be held on the
 * device, that the three-type foreground promotes without SecurityException, and
 * that a remote End Call (car head unit, BT headset, Android Auto) reaches
 * onSetCallDisconnected and tears the session down.
 *
 * It deliberately does NOT yet steer audio routing. The plugin's existing
 * setCommunicationDevice / MODE_IN_COMMUNICATION / audio-focus path still runs
 * underneath, unchanged. The endpoint collectors below only LOG what Telecom
 * offers and selects — they do not call requestEndpointChange. Handing routing to
 * Telecom (and removing the old path) is Build 2B, gated behind the proof that
 * this build's call lifecycle actually works in the car.
 *
 * Three original jobs of this service are preserved:
 *
 *  1. FOREGROUND SERVICE. On Android 14+, an app not in the foreground cannot hold
 *     the microphone unless it runs a typed foreground service. Under Telecom we
 *     promote with MICROPHONE + CONNECTED_DEVICE + PHONE_CALL together (exactly as
 *     Google's own Core-Telecom reference app does), because the promotion happens
 *     from a foreground context (the user just tapped Talk). Keeping the microphone
 *     type PRESERVES the screen-sleep-keeps-talking promise; adding phoneCall lets
 *     Telecom own the call; adding connectedDevice covers the car/BT transport.
 *
 *  2. PARTIAL WAKELOCK. CPU alive, screen allowed to sleep. Unchanged.
 *
 *  3. PERSISTENT NOTIFICATION. Required for any foreground service, and Core-Telecom
 *     additionally requires a notification within 5 seconds of adding the call.
 *     One notification serves both. Wording unchanged ("Talking with Claude").
 *
 * On API 24-25 (below Core-Telecom's floor of O/26) there is no Telecom call at
 * all: the service runs exactly as it did before (microphone-typed foreground +
 * wakelock), and the plugin's legacy audio path owns everything. Those devices do
 * not get car-hangup support, the same as today.
 *
 * PLUGIN <-> SERVICE BRIDGE (minimal, by design):
 * This service and the plugin communicate through two lightweight signals, sized
 * for the one-call-per-device reality (each phone ever holds exactly one Joe
 * conversation — "thousands of users" is thousands of isolated phones, never two
 * calls in one process):
 *   - plugin -> service: startForSession() / the disconnect request via
 *     requestDisconnect(), routed through the action channel into the scope.
 *   - service -> plugin: onRemoteDisconnect, a @Volatile companion callback the
 *     plugin arms while a session is live and nulls when idle (mirroring the
 *     existing carEndCallHandler idiom the raw-API build already proved). A remote
 *     End Call fires this; a stray event when idle finds null and does nothing.
 */
class VoiceSessionService : LifecycleService() {

    companion object {
        private const val TAG = "SixPagesVoice"
        private const val CHANNEL_ID = "six_pages_voice_session"
        private const val NOTIFICATION_ID = 8317

        // Wording locked with Amy: mirrors the "Talk with Claude" button.
        private const val NOTIF_TITLE = "Six Pages"
        private const val NOTIF_BODY = "Talking with Claude"

        // Voice-adapted call metadata. displayName is what a car head unit / BT
        // device shows for the call; "Claude" is the companion the user is talking
        // to. The address is a required non-null tel: URI for the call attributes;
        // it is never dialed — this is a self-managed VoIP call, not a PSTN call.
        private const val CALL_DISPLAY_NAME = "Claude"
        private const val CALL_ADDRESS = "tel:six-pages-voice"

        // SERVICE -> PLUGIN bridge. Armed by the plugin (startEngine) while a
        // session is live; nulled by the plugin (stopEngine) when idle. A remote
        // End Call (car / BT / Android Auto) invokes this to trigger plugin
        // teardown. Null-when-idle is the guard: a stray disconnect after teardown
        // finds null and does nothing. Mirrors the proven carEndCallHandler pattern.
        @Volatile
        var onRemoteDisconnect: (() -> Unit)? = null

        // PLUGIN -> SERVICE control. Set by the plugin before starting the service
        // so the service knows whether to open a Telecom call (API 26+) or run as a
        // plain microphone foreground service (API 24-25 / Telecom unavailable).
        // Read once in onStartCommand.
        @Volatile
        private var telecomRequested: Boolean = false

        // Live handle to the running service's disconnect entry point, so the
        // plugin's stopEngine (Stop button / voice-end) can ask Telecom to
        // disconnect the call. Set when the call's action loop is ready; nulled
        // when the call ends. Null means "no live Telecom call to disconnect."
        @Volatile
        private var disconnectRequester: (() -> Unit)? = null

        /**
         * Start the foreground service. [withTelecom] should be true only when the
         * caller has already confirmed API >= 26; the service re-checks anyway.
         */
        fun start(context: Context, withTelecom: Boolean) {
            telecomRequested = withTelecom
            val intent = Intent(context, VoiceSessionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            // Ask Telecom to disconnect the call first (if one is live), so the
            // framework and any remote surface (car dashboard) learn the call ended
            // before the service itself goes away. Safe no-op if no call is live.
            try {
                disconnectRequester?.invoke()
            } catch (e: Exception) {
                Log.w(TAG, "TELECOM_2A: disconnectRequester threw on stop — ${e.message}")
            }
            context.stopService(Intent(context, VoiceSessionService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    // The Telecom call's action channel and its scope job. Non-null only while a
    // call is live. disconnectChannel carries a local disconnect request into the
    // CallControlScope's select loop.
    private val disconnectChannel = Channel<Unit>(Channel.CONFLATED)
    private var callJob: Job? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        createChannel()

        val notification = buildNotification()
        promoteToForeground(notification)

        acquireWakeLock()

        val useTelecom = telecomRequested && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        Log.i(
            TAG,
            "VoiceSessionService started (foreground + wakelock) telecom=$useTelecom sdk=${Build.VERSION.SDK_INT}"
        )

        if (useTelecom) {
            startTelecomCall()
        }

        // If Android kills us under memory pressure, do NOT silently resurrect a
        // dead conversation with no socket behind it. The session is owned by the
        // plugin; a zombie service would show a notification for a chat that is gone.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // End the Telecom call cleanly if it is still live, then cancel its scope.
        try {
            disconnectChannel.trySend(Unit)
        } catch (e: Exception) {
            Log.w(TAG, "TELECOM_2A: disconnectChannel send failed on destroy — ${e.message}")
        }
        disconnectRequester = null
        callJob?.cancel()
        callJob = null
        releaseWakeLock()
        Log.i(TAG, "VoiceSessionService stopped (wakelock released)")
        super.onDestroy()
    }

    // ────────────────────────────────────────────────────────────────────────
    // Telecom call (API 26+ only)
    // ────────────────────────────────────────────────────────────────────────

    @RequiresApi(Build.VERSION_CODES.O)
    private fun startTelecomCall() {
        val callsManager = CallsManager(this)

        // CAPABILITY_BASELINE: audio only, no video, no experimental surface.
        callsManager.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE)

        val attributes = CallAttributesCompat(
            displayName = CALL_DISPLAY_NAME,
            address = android.net.Uri.parse(CALL_ADDRESS),
            direction = CallAttributesCompat.DIRECTION_OUTGOING,
            callType = CallAttributesCompat.CALL_TYPE_AUDIO_CALL
        )

        // The call lives on lifecycleScope: bound to this service's lifetime, so it
        // is automatically cancelled if the service is destroyed. addCall is a
        // suspend fun that stays suspended for the whole call; the CallControlScope
        // block is where we drive and observe it.
        callJob = lifecycleScope.launch {
            try {
                callsManager.addCall(
                    attributes,
                    onAnswer = { _ ->
                        // Outgoing self-managed call: no inbound answer path. Present
                        // to satisfy the callback contract.
                        Log.i(TAG, "TELECOM_2A: onAnswer (unexpected for outgoing) ")
                    },
                    onDisconnect = { cause ->
                        // REMOTE (or framework) disconnect: car End Call, BT device,
                        // Android Auto, or the framework itself. Notify the plugin to
                        // tear down. Keep this fast — we are inside the 5s contract
                        // window and heavy teardown must not block the lambda.
                        Log.w(TAG, "TELECOM_2A: onDisconnect cause=${cause.code} -> notifying plugin")
                        val cb = onRemoteDisconnect
                        if (cb != null) {
                            cb.invoke()
                        } else {
                            Log.i(TAG, "TELECOM_2A: onDisconnect but no plugin handler armed (idle) ")
                        }
                    },
                    onSetActive = {
                        Log.i(TAG, "TELECOM_2A: onSetActive")
                    },
                    onSetInactive = {
                        Log.i(TAG, "TELECOM_2A: onSetInactive")
                    }
                ) {
                    // ── Inside CallControlScope (receiver: CoroutineScope) ───────
                    // block is NOT suspend, but CallControlScope IS a CoroutineScope,
                    // so every suspend call below runs inside its own launch{}.

                    // Expose a local-disconnect entry point for the plugin's Stop
                    // button / voice-end path (routed through the select loop below).
                    disconnectRequester = { disconnectChannel.trySend(Unit) }

                    // Move the call to ACTIVE. This is what tells the platform (and
                    // the car dashboard) the call is up and running.
                    launch {
                        when (val r = setActive()) {
                            is CallControlResult.Success ->
                                Log.i(TAG, "TELECOM_2A: setActive OK")
                            is CallControlResult.Error ->
                                Log.e(TAG, "TELECOM_2A: setActive FAILED code=${r.errorCode}")
                        }
                    }

                    // ENDPOINT COLLECTORS — OBSERVE + ONE SURGICAL NUDGE (Option A).
                    // Full trust remains the rule: we do NOT force a route on every
                    // update, we do NOT fight the framework, and we NEVER override the
                    // car or a wired headset. Telecom's default (wired > BT/car >
                    // speaker > earpiece) stands — with ONE exception.
                    //
                    // The exception, confirmed from real device logs: untethered, with
                    // nothing connected, Telecom's default rests on EARPIECE. In-app,
                    // Six Pages is a hands-down companion conversation (phone on the
                    // table), so speaker is the right default there — not earpiece,
                    // which implies holding the phone to your face like a call. So:
                    //
                    //   IF the current endpoint is EARPIECE
                    //   AND no wired headset and no Bluetooth/car endpoint is available
                    //   AND we have not already nudged this session
                    //   THEN request speaker — ONCE — through Telecom's own sanctioned
                    //        requestEndpointChange API (not setCommunicationDevice).
                    //
                    // When the car (Uconnect) or a wired headset is present, the current
                    // endpoint is NOT earpiece, so the nudge does not fire and the car /
                    // headset is respected. The one-shot flag prevents any loop (our own
                    // change re-fires the collector) and prevents us from fighting a
                    // later manual choice (the future in-app speaker/earpiece toggle).
                    var latestEndpoints: List<CallEndpointCompat> = emptyList()
                    var nudgedToSpeaker = false

                    fun maybeNudgeToSpeaker(current: CallEndpointCompat) {
                        if (nudgedToSpeaker) return

                        // The trigger is ONE unambiguous signal: we are CURRENTLY
                        // resting on the earpiece. Nothing else. We deliberately do
                        // NOT look at what is merely *available*.
                        //
                        // Why (proven by a controlled device test, 2026-07-17):
                        // an earlier version blocked this nudge whenever ANY Bluetooth
                        // endpoint was *available*. But a passive smartwatch (Garmin
                        // Venu, Galaxy Watch, etc.) shows up in availableEndpoints as a
                        // TYPE_BLUETOOTH endpoint even though it is NOT the audio route
                        // and the user is not using it for audio. That idle watch was
                        // silently blocking the speaker nudge, leaving Joe on earpiece.
                        // Turning the watch's Bluetooth off made the nudge fire and Joe
                        // came up on speaker and HELD there all session — confirming the
                        // watch-in-the-available-list was the sole blocker.
                        //
                        // The fix: key on current == EARPIECE alone. If the car, a wired
                        // headset, or real BT headphones were the ACTIVE route, the
                        // current endpoint would BE that device (we saw currentEndpoint=
                        // Uconnect in the car), NOT earpiece. So "current == earpiece"
                        // already proves nothing better is active, and moving to speaker
                        // steals from nothing. A watch merely *available* is irrelevant.
                        if (current.type != CallEndpointCompat.TYPE_EARPIECE) return

                        val speaker = latestEndpoints.firstOrNull {
                            it.type == CallEndpointCompat.TYPE_SPEAKER
                        }
                        if (speaker == null) {
                            Log.i(TAG, "2B-nudge: on earpiece but no SPEAKER endpoint offered — leaving as-is")
                            return
                        }

                        nudgedToSpeaker = true
                        Log.i(TAG, "2B-nudge: in-app default earpiece -> requesting SPEAKER (${speaker.name})")
                        launch {
                            when (val r = requestEndpointChange(speaker)) {
                                is CallControlResult.Success ->
                                    Log.i(TAG, "2B-nudge: requestEndpointChange(SPEAKER) OK")
                                is CallControlResult.Error ->
                                    Log.e(TAG, "2B-nudge: requestEndpointChange(SPEAKER) FAILED code=${r.errorCode}")
                            }
                        }
                    }

                    launch {
                        availableEndpoints.collect { eps ->
                            latestEndpoints = eps
                            val list = eps.joinToString(", ") { "${it.name}(type=${it.type})" }
                            Log.i(TAG, "TELECOM_2A: availableEndpoints=[$list]")
                        }
                    }
                    launch {
                        currentCallEndpoint.collect { ep ->
                            Log.i(TAG, "TELECOM_2A: currentEndpoint=${ep.name} type=${ep.type}")
                            maybeNudgeToSpeaker(ep)
                        }
                    }
                    launch {
                        isMuted.collect { muted ->
                            Log.i(TAG, "TELECOM_2A: isMuted=$muted")
                        }
                    }

                    // Action loop: keep the scope alive and handle a LOCAL disconnect
                    // request (Stop button / voice-end / service destroy). A REMOTE
                    // disconnect arrives via the onDisconnect lambda above instead.
                    launch {
                        select<Unit> {
                            disconnectChannel.onReceive {
                                Log.i(TAG, "TELECOM_2A: local disconnect -> disconnect(LOCAL) ")
                                val cause = DisconnectCause(DisconnectCause.LOCAL)
                                when (val r = disconnect(cause)) {
                                    is CallControlResult.Success ->
                                        Log.i(TAG, "TELECOM_2A: disconnect OK")
                                    is CallControlResult.Error ->
                                        Log.e(TAG, "TELECOM_2A: disconnect FAILED code=${r.errorCode}")
                                }
                            }
                        }
                        disconnectRequester = null
                    }
                }
            } catch (e: Exception) {
                // addCall can throw (e.g. registration/permission problems). Log it
                // loudly for the car test; the plugin's audio path is independent and
                // is unaffected, so a Telecom failure here degrades to "no car-hangup"
                // rather than "no audio."
                Log.e(TAG, "TELECOM_2A: addCall threw — ${e.javaClass.simpleName}: ${e.message}")
                disconnectRequester = null
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Foreground, wakelock, notification
    // ────────────────────────────────────────────────────────────────────────

    private fun promoteToForeground(notification: Notification) {
        // FIX (2A crash): promote with MICROPHONE ONLY. We do NOT assert the
        // phoneCall / connectedDevice foreground types here.
        //
        // Why: Core-Telecom's addCall handles the PHONE_CALL foreground promotion
        // ITSELF — the platform contract is "once a call is added and a notification
        // is posted, your app is given foreground execution priority and is treated
        // as a foreground service." Calling startForeground(..., PHONE_CALL) here,
        // in onStartCommand BEFORE the Telecom call exists, made Android's
        // validateForegroundServiceType reject the promotion (there is no live call
        // for the phoneCall type to validate against), which threw and crashed the
        // app on every session start. The library owns the call foreground; we must
        // not race it or pre-assert it.
        //
        // What we DO need from our own service is the MICROPHONE type: it is what
        // legally holds mic capture when the screen sleeps (the screen-sleep-keeps-
        // talking promise). Microphone has no call precondition, so promoting it here
        // — from a foreground context, the user having just tapped Talk — is legal
        // and does not throw. The phoneCall/connectedDevice types remain DECLARED in
        // the manifest (the library needs them declared to do its own promotion), but
        // WE only pass microphone to startForeground.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
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
