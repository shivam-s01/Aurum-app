package com.aurum.music

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent

/**
 * Does nothing by itself. It exists only so [AurumIslandService] can put the
 * island pill in a TYPE_ACCESSIBILITY_OVERLAY window, which sits above the
 * system status bar. A normal app overlay sits below it, so on phones where
 * SystemUI owns the top strip (camera area) taps never reached the pill.
 * No events are read, no screen content is retrieved.
 *
 * Whenever this service connects/disconnects while the island is up, the
 * island service is restarted so its windows always live in the right
 * WindowManager (a11y overlay when connected, normal overlay otherwise).
 */
class AurumIslandAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: AurumIslandAccessibilityService? = null
            private set

        /** True if the user has this accessibility service switched on. */
        fun isEnabled(context: Context): Boolean {
            return try {
                val enabled = android.provider.Settings.Secure.getString(
                    context.contentResolver,
                    android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                ) ?: return false
                val me = "${context.packageName}/${AurumIslandAccessibilityService::class.java.name}"
                val meShort = "${context.packageName}/.${AurumIslandAccessibilityService::class.java.simpleName}"
                enabled.split(':').any {
                    it.equals(me, ignoreCase = true) || it.equals(meShort, ignoreCase = true)
                }
            } catch (_: Throwable) {
                false
            }
        }

        /** Restart the island (if running) so it re-picks its window host. */
        private fun rebuildIsland(appContext: Context) {
            if (!AurumIslandService.isRunning) return
            try {
                appContext.stopService(Intent(appContext, AurumIslandService::class.java))
            } catch (_: Throwable) {
            }
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    appContext.startService(Intent(appContext, AurumIslandService::class.java))
                } catch (_: Throwable) {
                }
            }, 300L)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        rebuildIsland(applicationContext)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        val ctx = applicationContext
        instance = null
        rebuildIsland(ctx)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }
}
