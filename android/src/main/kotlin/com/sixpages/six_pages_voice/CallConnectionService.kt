package com.sixpages.six_pages_voice

import android.os.Build
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.util.Log

/**
 * CallConnectionService — DIAGNOSTIC INSTRUMENT, NOT A FIX. NO AUDIO BEHAVIOR.
 * ---------------------------------------------------------------------------
 *
 * THE ONE BUG THIS INVESTIGATES:
 *   Android voice works PERFECTLY. It connects, holds the car route, AEC is clean.
 *   The ONLY problem: pressing "End Call" on the CAR HEAD UNIT does not hang up.
 *   The session migrates back to the phone and the mic stays live. A hands-free
 *   feature currently demands hands to end it. That is the safety issue.
 *
 * WHY THE CAR CAN'T HANG UP TODAY:
 *   Nothing in this app is registered with Android's Telecom framework as a
 *   "call." The car's End Call button sends the Bluetooth hangup command
 *   (AT+CHUP), but there is no Connection object for the framework to route it
 *   into, so it never reaches the app. stopEngine() is never called.
 *
 * WHAT THIS FILE DOES:
 *   Registers the app as a self-managed VoIP call so the car's hangup HAS
 *   somewhere to land: Connection.onDisconnect(). This build only PROVES the
 *   wire exists on the SM-S928U. It logs at every stage and, on a car hangup,
 *   writes a single unmistakable line. It does NOT tear down the audio yet.
 *   Wiring onDisconnect() -> stopEngine() is the NEXT build, only after this
 *   one proves the callback fires on this Samsung device.
 *
 * WHY INSTRUMENT SO HEAVILY:
 *   Two Samsung self-managed ConnectionService failures are documented where
 *   the expected callback SILENTLY NEVER FIRED (placeCall swallowed on some
 *   Samsung models). We will not learn that after building teardown on top of
 *   a dead callback. This instrument answers the WHOLE question in one car
 *   trip: did registration succeed? did the connection get created? did the
 *   car's hangup arrive? Each stage logs so a silent failure names itself.
 *
 * TAG: every line is under TELECOM_TEST so `adb logcat -s TELECOM_TEST` shows
 * the entire story with nothing else in the way.
 */
class CallConnectionService : ConnectionService() {

    companion object {
        const val TAG = "TELECOM_TEST"

        // Held so the plugin (or a later teardown wire) can reach the live
        // connection if needed. Diagnostic only in this build.
        @Volatile
        var activeConnection: SixPagesConnection? = null
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        Log.i(TAG, "STAGE 2a: onCreateOutgoingConnection FIRED — framework created our OUTGOING call")
        return buildConnection("outgoing")
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        Log.e(TAG, "STAGE 2a: onCreateOutgoingConnectionFailed — framework REJECTED our OUTGOING call. " +
            "This is the Samsung outgoing-swallow symptom. Try incoming.")
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        Log.i(TAG, "STAGE 2b: onCreateIncomingConnection FIRED — framework created our INCOMING call")
        return buildConnection("incoming")
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        Log.e(TAG, "STAGE 2b: onCreateIncomingConnectionFailed — framework REJECTED our INCOMING call.")
    }

    private fun buildConnection(direction: String): SixPagesConnection {
        val conn = SixPagesConnection()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            conn.connectionProperties = Connection.PROPERTY_SELF_MANAGED
        }
        // DIAGNOSTIC BUILD: we deliberately do NOT call setAudioModeIsVoip(true).
        // That is what makes Telecom try to OWN the audio, which would arbitrate
        // against the working focus/route path. This build must not touch audio.
        // The connection exists ONLY to receive the car's hangup. Audio ownership
        // is a decision for the NEXT build, once this callback is proven.
        conn.setAddress(null, android.telecom.TelecomManager.PRESENTATION_UNKNOWN)
        conn.setActive()  // mark the call live so the car shows an active call to hang up
        activeConnection = conn
        Log.i(TAG, "STAGE 2: SixPagesConnection built ($direction) and setActive() — car now has a call to end")
        return conn
    }

    /**
     * The connection object. Its onDisconnect() is THE ENTIRE POINT of this build:
     * it is where the car's End Call button lands — IF the Samsung telecom stack
     * delivers it. In this diagnostic it only logs; it does NOT call stopEngine().
     */
    class SixPagesConnection : Connection() {

        override fun onDisconnect() {
            // ============================================================
            // THE LINE WE DROVE TO THE CAR TO SEE.
            // If this fires after pressing End Call on the head unit, the
            // wire EXISTS on the SM-S928U and the next build routes it into
            // stopEngine(). If the car press produces NOTHING here, the
            // Samsung stack did not deliver the hangup to a self-managed call.
            // ============================================================
            Log.w(TAG, "STAGE 3: onDisconnect FIRED — CAR HANGUP RECEIVED. This is the wire we needed.")
            setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            destroy()
            activeConnection = null
        }

        override fun onAbort() {
            Log.w(TAG, "onAbort FIRED (call aborted by framework)")
            setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
            destroy()
            activeConnection = null
        }

        override fun onReject() {
            Log.w(TAG, "onReject FIRED")
            setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
            destroy()
            activeConnection = null
        }

        override fun onAnswer() {
            Log.i(TAG, "onAnswer FIRED")
            setActive()
        }
    }
}
