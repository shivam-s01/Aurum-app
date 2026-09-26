package com.aurum.music

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Debug

/**
 * Anti-tamper / anti-analysis surface.
 *
 * DESIGN CONTRACT — read before touching this file:
 * 1. NEVER hard-crash, NEVER block app launch, NEVER show a "rooted
 *    device detected" dialog. Every check here is best-effort signal
 *    only. A false positive on a genuine rooted power-user (a real,
 *    common segment for a music app like this) must never cost that
 *    user the ability to use the app.
 * 2. What checks here ARE allowed to do: (a) get logged locally for
 *    diagnostics, (b) gate the SEPARATE integrity-sensitive paths that
 *    explicitly opt in via `isSuspicious` (currently: nothing forced —
 *    see call site notes below), never core playback/UI.
 * 3. This raises cost for casual-to-intermediate reverse engineers
 *    (blocks the default Frida/Xposed/Magisk-hide-less setup, plain
 *    `adb shell run-as` + debugger attach, stock emulator testing). It
 *    does NOT and CANNOT stop a professional who roots their own
 *    analysis environment properly (custom ROM, patched Frida gadget,
 *    Magisk DenyList configured correctly, kernel-level hiding). No
 *    on-device check can — the code has to run on the device to work,
 *    which means it can always eventually be traced by someone willing
 *    to instrument the OS itself. This adds real friction, not a wall.
 */
internal object AurumIntegrityGuard {

    @Volatile
    private var nativeLibLoaded: Boolean = false

    init {
        // If the native lib fails to load on some exotic ABI/OEM combo,
        // that must never take the app down with it — fall back to
        // Kotlin-only signal rather than crashing on load.
        try {
            System.loadLibrary("aurumguard")
            nativeLibLoaded = true
        } catch (_: Throwable) {
            nativeLibLoaded = false
        }
    }

    /**
     * Debugger attach (native ptrace + TracerPid check), su-binary
     * presence, and the default-Frida maps scan now live in
     * aurum_guard.cpp — reading disassembled native code to recover
     * this logic is a meaningfully higher bar than reading decompiled
     * Kotlin, even obfuscated. See that file's own header comment for
     * the full contract; it is unchanged from this file's original one.
     */
    private external fun nativeCheckSuspicious(): Boolean

    /**
     * True if ANY tamper/analysis signal fired. Intentionally coarse
     * (doesn't say which) — the exact signal that fired is itself
     * useful information for an attacker probing what's checked, so a
     * caller only ever sees yes/no.
     *
     * Currently detect-and-log only — nothing in the app branches on
     * this flag yet. Any future caller must keep to this file's design
     * contract above: read the flag, never hard-block on it.
     */
    @Volatile
    var isSuspicious: Boolean = false
        private set

    private const val EXPECTED_PACKAGE = "com.aurum.music"

    /** Call once, early in MainActivity.onCreate() — cheap, non-blocking. */
    fun runChecks(context: Context) {
        isSuspicious = try {
            val nativeSignal = if (nativeLibLoaded) {
                try {
                    nativeCheckSuspicious()
                } catch (_: Throwable) {
                    // Same fail-closed rule as everywhere else: a native
                    // check throwing is not evidence of tampering.
                    false
                }
            } else {
                false
            }

            nativeSignal ||
                debuggerAttached() ||
                testKeysBuildPresent() ||
                rootAppsInstalled(context) ||
                knownHookingFrameworkPresent() ||
                packageIdentityMismatched(context) ||
                debuggableFlagSetInRelease(context)
        } catch (_: Throwable) {
            // A check throwing (e.g. SecurityException on a locked-down
            // OEM build) is itself not evidence of tampering — fail
            // closed to "not suspicious" so a weird-but-legitimate
            // device is never penalized for an inconclusive check.
            false
        }

        if (isSuspicious) {
            // Local diagnostic record only — nothing here alters app
            // behavior. Coarse on purpose (see isSuspicious's own doc
            // comment): logs that a signal fired, not which one.
            AurumDiagnosticLog.logEvent("IntegrityGuard", "Tamper/analysis signal detected on launch")
        }
    }

    // ---------------------------------------------------------------
    // Debugger / dynamic instrumentation — JDWP (Java-level) debugger.
    // The native ptrace-based check in aurum_guard.cpp covers native
    // attaches; this covers the managed-runtime debugger case that
    // check can't see, so both are still needed together.
    // ---------------------------------------------------------------

    private fun debuggerAttached(): Boolean =
        Debug.isDebuggerConnected() || Debug.waitingForDebugger()

    // ---------------------------------------------------------------
    // Root APP presence — package-manager lookups need a Context, which
    // the native layer doesn't have without extra JNI plumbing, so this
    // one stays in Kotlin. Su-binary path presence itself moved to
    // aurum_guard.cpp (suBinaryPresent()).
    // ---------------------------------------------------------------

    private val ROOT_APP_PACKAGES = arrayOf(
        "com.topjohnwu.magisk",
        "eu.chainfire.supersu",
        "com.noshufou.android.su",
        "com.koushikdutta.superuser",
        "com.thirdparty.superuser",
        "com.yellowes.su",
    )

    /** Custom/dev-signed builds ship with test-keys in Build.TAGS. */
    private fun testKeysBuildPresent(): Boolean =
        Build.TAGS?.contains("test-keys") == true

    private fun rootAppsInstalled(context: Context): Boolean {
        val pm = context.packageManager
        return ROOT_APP_PACKAGES.any { pkg ->
            try {
                pm.getPackageInfo(pkg, 0)
                true
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        }
    }

    // ---------------------------------------------------------------
    // Xposed / LSPosed — stack-frame based detection stays in Kotlin
    // since it inspects the JVM's own stack trace (Throwable), which
    // has no native equivalent; the Frida maps scan moved to
    // aurum_guard.cpp (fridaDefaultMapsSignal()).
    // ---------------------------------------------------------------

    private fun knownHookingFrameworkPresent(): Boolean {
        // Xposed / LSPosed leave a detectable stack frame or classloader
        // trace in the default, un-hidden configuration.
        try {
            throw Exception("aurum_stack_probe")
        } catch (e: Exception) {
            for (frame in e.stackTrace) {
                val cls = frame.className.lowercase()
                if (cls.contains("xposed") || cls.contains("lsposed")) return true
            }
        }
        return false
    }

    // ---------------------------------------------------------------
    // Package identity — catches the common "rebuild + resign under a
    // different applicationId to redistribute" case.
    // ---------------------------------------------------------------

    private fun packageIdentityMismatched(context: Context): Boolean =
        context.packageName != EXPECTED_PACKAGE

    // ---------------------------------------------------------------
    // Belt-and-suspenders: confirm the release manifest's debuggable
    // flag truly compiled to false. (build.gradle's release buildType
    // doesn't set debuggable — this just verifies that assumption
    // instead of silently trusting it forever.)
    // ---------------------------------------------------------------

    private fun debuggableFlagSetInRelease(context: Context): Boolean {
        val appInfo = context.applicationInfo
        val debuggableFlag = appInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE
        return debuggableFlag != 0
    }
}
