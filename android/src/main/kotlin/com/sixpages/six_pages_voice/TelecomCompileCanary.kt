package com.sixpages.six_pages_voice

import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallsManager

/**
 * BUILD 1 — DEPENDENCY PROOF ONLY. NOT A FEATURE. DELETE IN BUILD 2.
 *
 * This file exists for exactly one reason: to force the toolchain to RESOLVE,
 * COMPILE, and MANIFEST-MERGE `androidx.core:core-telecom:1.0.1` against this
 * project's specific stack (AGP 9.0.1 / Kotlin 2.3.20 / compileSdk 36 /
 * minSdk 24 / NDK r27). A dependency that nothing references gets no compile
 * pressure — Gradle would resolve it but never prove it compiles against our
 * coroutines/Kotlin metadata, and the manifest merger would never be exercised.
 *
 * So this object imports and touches the CORE Core-Telecom types we will build
 * the real migration on — CallsManager and CallAttributesCompat — inside a
 * function that is NEVER CALLED. Merely compiling it proves:
 *   1. The artifact resolves from Google's Maven in FlutterFlow's build env.
 *   2. Its transitive deps (guava-listenablefuture, annotation, coroutines)
 *      do not collide with the pinned toolchain.
 *   3. The library's own minSdk merges cleanly against this module's minSdk 24
 *      (the most likely sticky point — a manifest-merger failure fires HERE).
 *   4. CallsManager's @RequiresApi(O) gate compiles under our annotation setup.
 *
 * There is NO behavior change in Build 1. Nothing references this object. The
 * audio path, the service, the manifest, and the plugin are all untouched.
 * Build 2 deletes this file and does the real work.
 */
internal object TelecomCompileCanary {

    // Never called. Exists only to make the compiler chew on the library types.
    @RequiresApi(Build.VERSION_CODES.O)
    @Suppress("unused")
    private fun proveItCompiles(context: Context): String {
        val callsManager = CallsManager(context)
        // Touch a companion constant so CAPABILITY_BASELINE is also linked.
        val capability = CallsManager.CAPABILITY_BASELINE
        // Reference the attributes type and a direction constant without building
        // a real call — we are proving the symbols exist and link, nothing more.
        val directionOutgoing = CallAttributesCompat.DIRECTION_OUTGOING
        return "canary:${callsManager.hashCode()}:$capability:$directionOutgoing"
    }
}
