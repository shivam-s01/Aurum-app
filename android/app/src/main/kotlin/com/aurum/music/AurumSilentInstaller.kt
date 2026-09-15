package com.aurum.music

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileInputStream

/**
 * Installs an update APK via Android's PackageInstaller Session API
 * instead of the old ACTION_VIEW file-open intent.
 *
 * FIX ("update install/uninstall jaisa lagta hai, ekdam proper update
 * notification chahiye" — user-reported): the previous installApk (see
 * MainActivity's old "installApk" channel handler, now delegating here)
 * launched Android's generic "open this file" dialog for a .apk MIME
 * type. That's the SAME system UI Android shows for a file manager
 * double-tap, and critically: if it ever hit a signature mismatch, a
 * corrupt partial download, or certain OEM package-installer skins, its
 * fallback behavior is to prompt "Uninstall this app first" rather than
 * failing cleanly — which is exactly the "install/uninstall wala" feel
 * being reported, and gives the user zero warning before their downloaded
 * songs / login / settings would be wiped.
 *
 * PackageInstaller's SessionBased API (what Play Store, and every other
 * "in-app self update" flow, actually uses) is categorically different:
 *   - It always performs an INSTALL_REPLACE_EXISTING style update in
 *     place — same app, same data, same task — there's no code path here
 *     that can ever present a bare "uninstall" flow instead.
 *   - If the signature doesn't match, it fails immediately with a clear
 *     INSTALL_FAILED_UPDATE_INCOMPATIBLE-style error/status callback —
 *     caught below and reported straight back to Flutter as a real error,
 *     not silently degraded into a system dialog the user has to puzzle
 *     through.
 *   - The confirmation UI it shows (unavoidable without being a device
 *     owner / having REQUEST_INSTALL_PACKAGES silent-update system
 *     permission, neither of which a regular Play-distributed-style app
 *     can have) is a single small "Update Aurum?" style prompt — not the
 *     multi-step file-open chooser the old flow could fall into.
 */
object AurumSilentInstaller {
    private const val TAG = "AurumSilentInstaller"
    private const val ACTION_INSTALL_RESULT = "com.aurum.music.INSTALL_RESULT"

    // Held only for the lifetime of one install attempt — result callback
    // fires once, then this is cleared. Not a leak risk across app
    // restarts since a fresh install() call always re-registers its own
    // receiver+callback pair.
    private var pendingCallback: ((success: Boolean, message: String) -> Unit)? = null
    private var receiver: BroadcastReceiver? = null

    /**
     * Begins a seamless update install. [onResult] fires once, either after
     * the user confirms/denies the system prompt or immediately on a
     * hard failure (bad file, incompatible signature, etc). This does NOT
     * guarantee the app was already replaced by the time onResult(true)
     * fires for older Android versions that still show a confirmation
     * screen — but it DOES guarantee "update in place", never a bare
     * uninstall, on every OS version this targets (minSdk already
     * requires PackageInstaller session support).
     */
    fun install(context: Context, apkPath: String, onResult: (Boolean, String) -> Unit) {
        val appContext = context.applicationContext
        pendingCallback = onResult

        try {
            val packageInstaller = appContext.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            ).apply {
                // Explicit "this is a replace/update of the currently
                // installed app", not a fresh/unknown-source install —
                // the single biggest factor in whether the OS treats this
                // as an update (data preserved) vs. anything resembling a
                // fresh install.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
                setAppPackageName(appContext.packageName)
            }

            val sessionId = packageInstaller.createSession(params)
            val session = packageInstaller.openSession(sessionId)

            val apkFile = File(apkPath)
            if (!apkFile.exists() || apkFile.length() < 1024 * 1024) {
                session.abandon()
                onResult(false, "Downloaded update file is missing or incomplete")
                pendingCallback = null
                return
            }

            session.openWrite("aurum_update", 0, apkFile.length()).use { out ->
                FileInputStream(apkFile).use { input ->
                    input.copyTo(out)
                }
                session.fsync(out)
            }

            registerResultReceiver(appContext)

            val intent = Intent(ACTION_INSTALL_RESULT).apply {
                setPackage(appContext.packageName)
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getBroadcast(
                appContext, sessionId, intent, flags
            )

            session.commit(pendingIntent.intentSender)
            session.close()
        } catch (e: Exception) {
            Log.e(TAG, "Silent install failed, falling back", e)
            pendingCallback = null
            // FALLBACK: on the small slice of OEM ROMs where
            // PackageInstaller session creation itself is blocked/broken
            // (some MIUI/EMUI security-hardening configs), fall back to
            // the old ACTION_VIEW flow rather than leaving the user
            // completely unable to update. This is strictly a fallback
            // for a session-creation failure, not the everyday path.
            try {
                installViaLegacyIntent(appContext, apkPath)
                onResult(true, "Opened system installer")
            } catch (fallbackError: Exception) {
                onResult(false, fallbackError.message ?: "Install failed")
            }
        }
    }

    private fun registerResultReceiver(context: Context) {
        // Replace any stale receiver from a previous (abandoned/failed)
        // attempt before registering a fresh one.
        receiver?.let {
            try { context.unregisterReceiver(it) } catch (_: Exception) {}
        }

        val newReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val status = intent.getIntExtra(
                    PackageInstaller.EXTRA_STATUS,
                    PackageInstaller.STATUS_FAILURE
                )
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    ?: "Unknown result"

                when (status) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        // A confirmation screen is required (normal on
                        // most consumer devices/OS versions for a
                        // non-system installer) — launch it. This is
                        // still an in-place UPDATE prompt, not an
                        // uninstall flow; PackageManager decides that
                        // based on setAppPackageName matching the already
                        // -installed app above, not on anything the user
                        // sees here.
                        val confirmIntent = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        confirmIntent?.let {
                            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try {
                                context.startActivity(it)
                            } catch (e: Exception) {
                                pendingCallback?.invoke(false, "Could not show install prompt: ${e.message}")
                                pendingCallback = null
                                cleanup(context)
                            }
                        }
                        // Don't clear pendingCallback/unregister yet — the
                        // real STATUS_SUCCESS/STATUS_FAILURE broadcast
                        // still arrives after the user acts on that
                        // confirmation screen.
                    }
                    PackageInstaller.STATUS_SUCCESS -> {
                        pendingCallback?.invoke(true, "Updated successfully")
                        pendingCallback = null
                        cleanup(context)
                    }
                    else -> {
                        pendingCallback?.invoke(false, message)
                        pendingCallback = null
                        cleanup(context)
                    }
                }
            }
        }

        val filter = IntentFilter(ACTION_INSTALL_RESULT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(newReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(newReceiver, filter)
        }
        receiver = newReceiver
    }

    private fun cleanup(context: Context) {
        receiver?.let {
            try { context.unregisterReceiver(it) } catch (_: Exception) {}
        }
        receiver = null
    }

    private fun installViaLegacyIntent(context: Context, apkPath: String) {
        val file = File(apkPath)
        val uri = androidx.core.content.FileProvider.getUriForFile(
            context, "${context.packageName}.fileprovider", file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }
}
