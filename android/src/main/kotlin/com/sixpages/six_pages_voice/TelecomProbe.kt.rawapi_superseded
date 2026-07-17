package com.sixpages.six_pages_voice

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log

/**
 * TelecomProbe — DIAGNOSTIC INSTRUMENT, NOT A FIX. NO AUDIO BEHAVIOR.
 * ---------------------------------------------------------------------------
 *
 * Registers a self-managed PhoneAccount and places a self-managed call, so the
 * car's End Call button has a Connection to land on (see CallConnectionService).
 *
 * This is the "does the wire exist on the SM-S928U" instrument. It is called
 * from startEngine() ALONGSIDE the existing VoiceSessionService.start() — it
 * does NOT replace, reorder, or touch any audio, focus, or route call. If any
 * of this fails, it logs and RETURNS. The voice session proceeds exactly as it
 * does today. Telecom failure must never break the working audio.
 *
 * STAGE LOGGING (all under TELECOM_TEST):
 *   STAGE 0  — feature/permission preflight
 *   STAGE 1  — PhoneAccount registration result
 *   STAGE 1b — is the account enabled? (Samsung sometimes registers-but-disables)
 *   STAGE 2  — placeCall issued (the framework then calls CallConnectionService)
 *
 * The remaining stages (2a/2b/3) are logged inside CallConnectionService.
 */
object TelecomProbe {

    private const val TAG = CallConnectionService.TAG
    private const val ACCOUNT_ID = "six_pages_voice_selfmanaged"

    @Volatile
    private var registered = false

    private fun handle(context: Context): PhoneAccountHandle {
        val component = ComponentName(context, CallConnectionService::class.java)
        return PhoneAccountHandle(component, ACCOUNT_ID)
    }

    /**
     * Register the self-managed PhoneAccount ONCE. Safe to call every session;
     * it no-ops after the first success. Guarded for API 26+ (self-managed floor).
     */
    fun ensureRegistered(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            Log.i(TAG, "STAGE 0: SDK ${Build.VERSION.SDK_INT} < 26 — self-managed unavailable, skipping (audio unaffected)")
            return
        }
        if (registered) return

        val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        if (tm == null) {
            Log.e(TAG, "STAGE 0: TelecomManager unavailable — cannot register")
            return
        }

        try {
            val h = handle(context)
            val account = PhoneAccount.builder(h, "Six Pages")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .build()
            tm.registerPhoneAccount(account)
            registered = true
            Log.i(TAG, "STAGE 1: registerPhoneAccount SUCCEEDED")

            // Samsung sometimes registers the account but leaves it disabled,
            // and placeCall then silently fails. Read it back and log.
            val readBack = tm.getPhoneAccount(h)
            if (readBack == null) {
                Log.e(TAG, "STAGE 1b: account read-back is NULL — registered but not retrievable (Samsung quirk?)")
            } else {
                Log.i(TAG, "STAGE 1b: account read-back OK, isEnabled=${readBack.isEnabled}")
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "STAGE 1: registerPhoneAccount FAILED (SecurityException) — is MANAGE_OWN_CALLS granted? ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "STAGE 1: registerPhoneAccount FAILED — ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * Place a self-managed OUTGOING call. This is the semantic match for
     * "user tapped Talk." The framework responds by calling
     * CallConnectionService.onCreateOutgoingConnection (STAGE 2a) — UNLESS the
     * Samsung stack swallows it, which STAGE 2a's Failed variant will name.
     */
    fun placeOutgoing(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
        try {
            val extras = Bundle().apply {
                putParcelable(
                    TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE,
                    handle(context)
                )
            }
            // A self-managed VoIP call is addressed with a sip:/tel: style URI.
            // There is no real callee; this is a placeholder so the framework
            // has a well-formed address. It is never dialed anywhere.
            val address = Uri.fromParts("sip", "claude@sixpages", null)
            tm.placeCall(address, extras)
            Log.i(TAG, "STAGE 2: placeCall(OUTGOING) issued — awaiting onCreateOutgoingConnection")
        } catch (e: SecurityException) {
            Log.e(TAG, "STAGE 2: placeCall FAILED (SecurityException) — MANAGE_OWN_CALLS / CALL_PHONE? ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "STAGE 2: placeCall FAILED — ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * Fallback: register the call as INCOMING (an "incoming call from Claude"
     * that is immediately active). Some Samsung models honor incoming while
     * swallowing outgoing. This build issues OUTGOING by default; this method
     * exists so the NEXT build can flip to incoming WITHOUT new research if
     * STAGE 2a shows the outgoing-swallow. Not called automatically here —
     * one variable per build.
     */
    fun addIncoming(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
        try {
            val extras = Bundle().apply {
                putParcelable(
                    TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                    Uri.fromParts("sip", "claude@sixpages", null)
                )
            }
            tm.addNewIncomingCall(handle(context), extras)
            Log.i(TAG, "STAGE 2: addNewIncomingCall issued — awaiting onCreateIncomingConnection")
        } catch (e: SecurityException) {
            Log.e(TAG, "STAGE 2: addNewIncomingCall FAILED (SecurityException) — ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "STAGE 2: addNewIncomingCall FAILED — ${e.javaClass.simpleName}: ${e.message}")
        }
    }
}
