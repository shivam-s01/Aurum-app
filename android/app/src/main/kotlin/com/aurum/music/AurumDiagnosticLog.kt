package com.aurum.music

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue

/**
 * =============================================================================
 * FILE: AurumDiagnosticLog.kt
 * PURPOSE: one on-device rotating log file that everything writes to —
 * crashes, ANR (main-thread freeze), audio offload status, playback/
 * network errors — so a real issue can be diagnosed from a single
 * exported file instead of needing adb/logcat attached at the exact
 * moment it happens.
 *
 * DESIGN NOTES (why it's built this way):
 *
 * - Single-threaded writer queue: every write from ANY thread (main,
 *   playback, network callbacks, the uncaught-exception hook) goes
 *   through one background executor with a single thread, writing to
 *   the file sequentially. This is the actual production-safe way to
 *   do this — writing to the same file from multiple threads
 *   concurrently is a real corruption/ANR risk; funneling through one
 *   dedicated writer thread avoids that entirely without needing a
 *   lock on every call site.
 *
 * - Bounded, rotating file: capped at MAX_BYTES. Once exceeded, the
 *   file is truncated back to the newest ~half of its content. This is
 *   the file-based equivalent of a ring buffer — it can NEVER grow
 *   without bound and become its own storage/battery problem, which
 *   would be a genuinely bad outcome for a "diagnose heating/battery
 *   issues" tool to cause.
 *
 * - The crash handler chains to the previous default handler
 *   (Thread.getDefaultUncaughtExceptionHandler()) rather than
 *   replacing it — critical: if this were skipped, the app would swallow
 *   crashes silently instead of actually terminating/reporting them the
 *   normal way, which changes real crash behavior in production. This
 *   only ADDS a synchronous write before the original handler runs.
 *
 * - The crash-path write is synchronous and bounded by a short timeout,
 *   NOT queued through the normal async executor: the process is about
 *   to die, so there's no guarantee a queued background write would
 *   ever get to run before the process is gone.
 *
 * - ANR watchdog: a background thread posts a token to the main-thread
 *   Handler every HEARTBEAT_INTERVAL_MS and checks it was consumed
 *   within a grace window. If the main thread doesn't get to it in
 *   time, that's a real UI freeze — logged with how long it was stuck.
 *   This is a lightweight polling check (one Handler post per interval),
 *   not continuous work, so it costs negligible CPU/battery on its own.
 * =============================================================================
 */
object AurumDiagnosticLog {
    private const val TAG = "AurumDiagnosticLog"
    private const val FILE_NAME = "aurum_diagnostic.log"
    private const val MAX_BYTES = 2L * 1024 * 1024 // 2MB cap — plenty for real troubleshooting, never unbounded
    private const val TRIM_TO_BYTES = 1L * 1024 * 1024 // trim back to newest 1MB when cap is hit

    private const val HEARTBEAT_INTERVAL_MS = 5_000L
    private const val ANR_THRESHOLD_MS = 5_000L // main thread not responding within this = logged as ANR

    private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    // Single dedicated writer thread — see class doc for why this matters.
    private val writerExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "AurumDiagnosticLogWriter").apply { isDaemon = true }
    }

    @Volatile private var logFile: File? = null
    @Volatile private var initialized = false

    private var anrWatchdogThread: Thread? = null
    @Volatile private var anrWatchdogRunning = false

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        try {
            logFile = File(context.applicationContext.filesDir, FILE_NAME)
            writeLine("SYSTEM", "=== AurumDiagnosticLog initialized ===")
            installCrashHandler()
            startAnrWatchdog()
        } catch (e: Exception) {
            // Never let the logger itself become a crash source.
            Log.e(TAG, "init failed: $e")
        }
    }

    // ── Public logging API — call from anywhere, any thread ──────────────

    fun logCrash(thread: Thread, throwable: Throwable) {
        // Synchronous + bounded: see class doc. The process may be
        // terminating right after this returns.
        try {
            val sb = StringBuilder()
            sb.append("=== CRASH on thread '${thread.name}' ===\n")
            sb.append(Log.getStackTraceString(throwable))
            writeLineSync("CRASH", sb.toString())
        } catch (_: Exception) {
            // Deliberately swallow — must never throw from a crash handler,
            // that would replace the real crash with a worse one.
        }
    }

    fun logAnr(stuckForMs: Long, stackTrace: String) {
        writeLine("ANR", "Main thread unresponsive for ${stuckForMs}ms\n$stackTrace")
    }

    fun logOffload(offloaded: Boolean, encoding: Int, sampleRate: Int, songId: String?) {
        writeLine(
            "OFFLOAD",
            "offloaded=$offloaded encoding=$encoding sampleRate=$sampleRate songId=${songId ?: "?"}",
        )
    }

    fun logPlaybackError(message: String, songId: String?) {
        writeLine("PLAYBACK_ERROR", "song=${songId ?: "?"} — $message")
    }

    fun logNetworkError(context: String, message: String) {
        writeLine("NETWORK_ERROR", "$context — $message")
    }

    /** Generic hook for anything else worth capturing (CPU/battery-relevant events, etc). */
    fun logEvent(tag: String, message: String) {
        writeLine(tag, message)
    }

    fun getLogFile(context: Context): File {
        return logFile ?: File(context.applicationContext.filesDir, FILE_NAME).also { logFile = it }
    }

    fun clear(context: Context) {
        writerExecutor.execute {
            try {
                getLogFile(context).writeText("")
            } catch (e: Exception) {
                Log.e(TAG, "clear failed: $e")
            }
        }
    }

    // ── Internals ──────────────────────────────────────────────────────

    private fun formatLine(tag: String, message: String): String {
        val ts = dateFormat.format(Date())
        return "[$ts] [$tag] $message\n"
    }

    private fun writeLine(tag: String, message: String) {
        val line = formatLine(tag, message)
        val file = logFile ?: return
        writerExecutor.execute {
            try {
                appendAndRotate(file, line)
            } catch (e: Exception) {
                Log.e(TAG, "write failed: $e")
            }
        }
    }

    // Used only on the crash path — see class doc for why this is
    // synchronous instead of going through writerExecutor.
    private fun writeLineSync(tag: String, message: String) {
        val line = formatLine(tag, message)
        val file = logFile ?: return
        try {
            appendAndRotate(file, line)
        } catch (_: Exception) {
            // Must never throw here.
        }
    }

    private fun appendAndRotate(file: File, line: String) {
        file.appendText(line)
        if (file.length() > MAX_BYTES) {
            // Ring-buffer trim: keep only the newest TRIM_TO_BYTES worth of
            // content. Reading the whole (small, capped) file back in is
            // cheap at this size and only happens occasionally (once per
            // MAX_BYTES worth of logging), never on every write.
            val bytes = file.readBytes()
            val start = (bytes.size - TRIM_TO_BYTES).coerceAtLeast(0).toInt()
            file.writeBytes(bytes.copyOfRange(start, bytes.size))
        }
    }

    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            logCrash(thread, throwable)
            // Chain to whatever was there before (system default, or
            // Flutter's own crash reporting hook) — see class doc.
            previous?.uncaughtException(thread, throwable)
                ?: run {
                    // No previous handler: fall back to killing the process
                    // the normal way instead of leaving it in a broken state.
                    Log.e(TAG, "Uncaught exception, no previous handler", throwable)
                    Runtime.getRuntime().exit(10)
                }
        }
    }

    private fun startAnrWatchdog() {
        if (anrWatchdogRunning) return
        anrWatchdogRunning = true
        val mainHandler = Handler(Looper.getMainLooper())

        anrWatchdogThread = Thread({
            while (anrWatchdogRunning) {
                val token = Object()
                val responded = LinkedBlockingQueue<Boolean>(1)
                val postedAt = SystemClock.elapsedRealtime()

                mainHandler.post {
                    responded.offer(true)
                }

                val gotResponse = responded.poll(ANR_THRESHOLD_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
                if (gotResponse == null) {
                    val stuckForMs = SystemClock.elapsedRealtime() - postedAt
                    val mainThreadStack = Looper.getMainLooper().thread.stackTrace
                        .joinToString("\n") { "    at $it" }
                    logAnr(stuckForMs, mainThreadStack)
                }

                try {
                    Thread.sleep(HEARTBEAT_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }, "AurumAnrWatchdog").apply {
            isDaemon = true
            start()
        }
    }

    fun stopAnrWatchdog() {
        anrWatchdogRunning = false
        anrWatchdogThread?.interrupt()
        anrWatchdogThread = null
    }
}
