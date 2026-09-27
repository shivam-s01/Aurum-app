package com.aurum.music

import android.animation.ValueAnimator
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.widget.ImageView
import android.widget.SeekBar
import android.widget.TextView
import androidx.media3.common.Player
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL
import kotlin.random.Random

/**
 * Dynamic-Island-style overlay: a small pill near the camera cutout while
 * something plays, tap-to-expand into a Spotify-red-card-style panel
 * (Aurum gold/dark instead of red), auto-collapsing back after a few
 * seconds. Runs entirely as a WindowManager overlay (SYSTEM_ALERT_WINDOW) —
 * no notification of its own, no separate foreground promotion; it rides
 * on AurumMediaSessionService's already-foreground lifetime and is
 * started/stopped by MainActivity's MethodChannel calls
 * (startIslandOverlay/stopIslandOverlay).
 *
 * State comes straight off [AurumMediaSessionService.sharedEngine]'s
 * ExoPlayer — same source of truth AurumWidgetProvider already reads from
 * — via a [Player.Listener] registered in onCreate() and torn down in
 * onDestroy().
 */
class AurumIslandService : Service() {

    companion object {
        private const val TAG = "AurumIslandService"
        private const val AUTO_COLLAPSE_MS = 4_500L

        // Waveform bar heights in dp — MIN/MAX bound the random animation
        // range while playing; IDLE is the flat height bars settle to
        // when paused/stopped (matches island_pill.xml's resting heights
        // so there's no visible jump when the animation stops).
        private const val WAVE_BAR_MIN_DP = 4f
        private const val WAVE_BAR_MAX_DP = 16f
        private const val WAVE_BAR_IDLE_DP = 6f
        private const val WAVE_ANIM_MIN_MS = 260L
        private const val WAVE_ANIM_MAX_MS = 420L

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private lateinit var windowManager: WindowManager
    private var pillView: View? = null
    private var expandedView: View? = null
    private var isExpanded = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var autoCollapseJob: Job? = null
    private var lastArtworkUrl: String? = null
    private var lastPillBitmap: Bitmap? = null
    private var lastExpandedBitmap: Bitmap? = null
    private var seekTicker: Job? = null

    private var playerListener: Player.Listener? = null

    // One looping ValueAnimator per bar, each with its own random
    // duration/height target so the three bars don't move in lockstep —
    // that's what actually reads as a "dancing waveform" instead of a
    // single pulsing block. Started on isPlaying=true, stopped (and bars
    // reset to the idle height) on isPlaying=false/pause/no song.
    private var waveAnimators: List<ValueAnimator>? = null
    private var waveBarsRunning = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        isRunning = true
        addPillView()
        registerPlayerListener()
        refreshFromPlayer()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Sticky-restart isn't useful here — if the process/service dies,
        // MainActivity re-issues startIslandOverlay on next onStart() the
        // same way it re-binds AurumMediaSessionService.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        unregisterPlayerListener()
        autoCollapseJob?.cancel()
        seekTicker?.cancel()
        stopWaveBars()
        removePillView()
        removeExpandedView()
        lastPillBitmap?.let { if (!it.isRecycled) it.recycle() }
        lastExpandedBitmap?.let { if (!it.isRecycled) it.recycle() }
        lastPillBitmap = null
        lastExpandedBitmap = null
        isRunning = false
        super.onDestroy()
    }

    // ---- Player state sync ------------------------------------------------

    private fun registerPlayerListener() {
        val player = AurumMediaSessionService.sharedEngine?.player ?: return
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                refreshFromPlayer()
            }
            override fun onMediaMetadataChanged(mediaMetadata: androidx.media3.common.MediaMetadata) {
                refreshFromPlayer()
            }
            override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) {
                refreshFromPlayer()
            }
        }
        player.addListener(listener)
        playerListener = listener
    }

    private fun unregisterPlayerListener() {
        val player = AurumMediaSessionService.sharedEngine?.player
        playerListener?.let { player?.removeListener(it) }
        playerListener = null
    }

    private fun refreshFromPlayer() {
        val engine = AurumMediaSessionService.sharedEngine
        val player = engine?.player
        val metadata = player?.mediaMetadata
        val hasSong = player != null && player.mediaItemCount > 0 && !metadata?.title.toString().isNullOrEmpty()

        if (!hasSong) {
            // Nothing playing/queued — hide entirely rather than show an
            // empty pill; app minimize/kill also routes through here since
            // MainActivity calls stopIslandOverlay on its own onStop, but
            // this covers "queue emptied while overlay is up" too.
            stopWaveBars()
            return
        }

        val title = metadata?.title?.toString() ?: ""
        val artist = metadata?.artist?.toString() ?: ""
        val artworkUri = metadata?.artworkUri?.toString()
        val isPlaying = player?.isPlaying == true

        pillView?.let { startOrStopWaveBars(isPlaying) }

        expandedView?.let { view ->
            view.findViewById<TextView>(R.id.island_expanded_title)?.text = title
            view.findViewById<TextView>(R.id.island_expanded_artist)?.text = artist
            view.findViewById<ImageView>(R.id.island_expanded_play_pause)?.setImageResource(
                if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
            )
            updateSeekbar(player)
            updateQueueThumbnails(player)
        }

        if (artworkUri != lastArtworkUrl) {
            lastArtworkUrl = artworkUri
            loadArtwork(artworkUri)
        }
    }

    private fun updateSeekbar(player: Player?) {
        if (player == null) return
        val duration = player.duration.takeIf { it > 0 } ?: 1L
        val position = player.currentPosition.coerceIn(0L, duration)
        val seekbar = expandedView?.findViewById<SeekBar>(R.id.island_expanded_seekbar)
        seekbar?.max = 1000
        seekbar?.progress = ((position.toDouble() / duration.toDouble()) * 1000).toInt()
        expandedView?.findViewById<TextView>(R.id.island_expanded_position)?.text = formatMs(position)
        expandedView?.findViewById<TextView>(R.id.island_expanded_duration)?.text =
            if (player.duration > 0) formatMs(player.duration) else "0:00"
    }

    // ---- Waveform bar animation --------------------------------------------

    private fun dpToPx(dp: Float): Int =
        (dp * resources.displayMetrics.density).toInt()

    /** Starts (if not already running) or stops+resets the 3-bar waveform
     *  in the pill, based on whether audio is actually playing. No-op if
     *  the pill isn't currently showing (e.g. card is expanded). */
    private fun startOrStopWaveBars(isPlaying: Boolean) {
        val root = pillView ?: return
        if (isPlaying) {
            if (waveBarsRunning) return
            waveBarsRunning = true
            val bars = listOf(
                root.findViewById<View>(R.id.island_wave_bar_1),
                root.findViewById<View>(R.id.island_wave_bar_2),
                root.findViewById<View>(R.id.island_wave_bar_3),
            )
            waveAnimators = bars.mapNotNull { bar ->
                if (bar == null) return@mapNotNull null
                animateBarLoop(bar)
            }
        } else {
            stopWaveBars()
        }
    }

    /** One bar's endless random height animation. Each iteration animates
     *  to a fresh random target height over a fresh random duration, then
     *  immediately queues the next one via doOnEnd — this is what gives
     *  each bar its own independent, non-repeating rhythm instead of a
     *  fixed loop that would look mechanical. */
    private fun animateBarLoop(bar: View): ValueAnimator {
        val minPx = dpToPx(WAVE_BAR_MIN_DP)
        val maxPx = dpToPx(WAVE_BAR_MAX_DP)
        val startHeight = bar.layoutParams?.height?.takeIf { it > 0 } ?: minPx

        fun nextAnimator(fromPx: Int): ValueAnimator {
            val toPx = Random.nextInt(minPx, maxPx + 1)
            val durationMs = Random.nextLong(WAVE_ANIM_MIN_MS, WAVE_ANIM_MAX_MS + 1)
            return ValueAnimator.ofInt(fromPx, toPx).apply {
                duration = durationMs
                interpolator = LinearInterpolator()
                addUpdateListener { anim ->
                    val h = anim.animatedValue as Int
                    bar.layoutParams = bar.layoutParams?.apply { height = h }
                    bar.requestLayout()
                }
            }
        }

        var current = nextAnimator(startHeight)
        current.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: android.animation.Animator) {
                if (!waveBarsRunning) return
                val lastHeight = (animation as ValueAnimator).animatedValue as Int
                val next = nextAnimator(lastHeight)
                // Replace this animator's slot so stopWaveBars() can still
                // find and cancel whichever instance is currently live.
                waveAnimators = waveAnimators?.map { if (it === animation) next else it }
                next.addListener(this)
                next.start()
            }
        })
        current.start()
        return current
    }

    /** Cancels all running bar animators and resets every bar back to its
     *  flat idle height — called on pause, on no-song, and on service
     *  teardown so nothing keeps animating (and burning battery) once the
     *  pill isn't actively showing "playing". */
    private fun stopWaveBars() {
        waveBarsRunning = false
        waveAnimators?.forEach { it.cancel() }
        waveAnimators = null
        val root = pillView ?: return
        val idlePx = dpToPx(WAVE_BAR_IDLE_DP)
        listOf(
            root.findViewById<View>(R.id.island_wave_bar_1),
            root.findViewById<View>(R.id.island_wave_bar_2),
            root.findViewById<View>(R.id.island_wave_bar_3),
        ).forEach { bar ->
            bar?.layoutParams = bar?.layoutParams?.apply { height = idlePx }
            bar?.requestLayout()
        }
    }

    private fun formatMs(ms: Long): String {
        val totalSec = ms / 1000
        val min = totalSec / 60
        val sec = totalSec % 60
        return String.format("%d:%02d", min, sec)
    }

    private fun startSeekTicker() {
        seekTicker?.cancel()
        seekTicker = scope.launch {
            while (isExpanded) {
                updateSeekbar(AurumMediaSessionService.sharedEngine?.player)
                delay(500)
            }
        }
    }

    private fun updateQueueThumbnails(player: Player) {
        val ids = listOf(
            R.id.island_queue_thumb_1,
            R.id.island_queue_thumb_2,
            R.id.island_queue_thumb_3,
            R.id.island_queue_thumb_4,
        )
        val startIdx = player.currentMediaItemIndex + 1
        for ((offset, viewId) in ids.withIndex()) {
            val idx = startIdx + offset
            val imageView = expandedView?.findViewById<ImageView>(viewId) ?: continue
            if (idx >= player.mediaItemCount) {
                imageView.setImageResource(R.drawable.ic_widget_play)
                imageView.alpha = 0.25f
                continue
            }
            imageView.alpha = 1f
            val uri = player.getMediaItemAt(idx).mediaMetadata.artworkUri?.toString()
            if (uri.isNullOrEmpty()) {
                imageView.setImageResource(R.drawable.ic_widget_play)
            } else {
                scope.launch {
                    val bmp = withContext(Dispatchers.IO) { downloadBitmap(uri) }
                    if (bmp != null) imageView.setImageBitmap(bmp)
                }
            }
        }
    }

    private fun loadArtwork(urlString: String?) {
        if (urlString.isNullOrEmpty()) {
            pillView?.findViewById<ImageView>(R.id.island_pill_artwork)?.setImageResource(R.drawable.ic_widget_play)
            expandedView?.findViewById<ImageView>(R.id.island_expanded_artwork)?.setImageResource(R.drawable.ic_widget_play)
            return
        }
        scope.launch {
            val bmp = withContext(Dispatchers.IO) { downloadBitmap(urlString) } ?: return@launch
            lastPillBitmap?.let { if (!it.isRecycled) it.recycle() }
            lastExpandedBitmap?.let { if (!it.isRecycled) it.recycle() }
            lastPillBitmap = bmp
            lastExpandedBitmap = bmp
            pillView?.findViewById<ImageView>(R.id.island_pill_artwork)?.setImageBitmap(bmp)
            expandedView?.findViewById<ImageView>(R.id.island_expanded_artwork)?.setImageBitmap(bmp)
        }
    }

    private fun downloadBitmap(urlString: String): Bitmap? {
        return try {
            URL(urlString).openStream().use { stream ->
                val opts = BitmapFactory.Options().apply { inSampleSize = 4 }
                BitmapFactory.decodeStream(stream, null, opts)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "downloadBitmap failed: ${e.message}")
            null
        }
    }

    // ---- Overlay view lifecycle --------------------------------------------

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

    private fun addPillView() {
        if (pillView != null) return
        val inflater = LayoutInflater.from(this)
        val view = inflater.inflate(R.layout.island_pill, null)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        params.y = 12

        view.setOnClickListener { expand() }

        try {
            windowManager.addView(view, params)
            pillView = view
        } catch (e: Throwable) {
            Log.e(TAG, "addPillView failed: ${e.message}", e)
        }
    }

    private fun removePillView() {
        // Cancel bar animators BEFORE tearing down the view — an animator
        // update firing after windowManager.removeView() would call
        // requestLayout() on a view no longer attached to any window,
        // which is harmless on most OEMs but not guaranteed safe on all.
        stopWaveBars()
        pillView?.let {
            try { windowManager.removeView(it) } catch (_: Throwable) {}
        }
        pillView = null
    }

    private fun addExpandedView() {
        if (expandedView != null) return
        val inflater = LayoutInflater.from(this)
        val view = inflater.inflate(R.layout.island_expanded, null)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        params.y = 12

        wireExpandedControls(view)

        try {
            windowManager.addView(view, params)
            expandedView = view
        } catch (e: Throwable) {
            Log.e(TAG, "addExpandedView failed: ${e.message}", e)
        }
    }

    private fun removeExpandedView() {
        expandedView?.let {
            try { windowManager.removeView(it) } catch (_: Throwable) {}
        }
        expandedView = null
    }

    private fun wireExpandedControls(view: View) {
        val engine = { AurumMediaSessionService.sharedEngine }
        view.findViewById<ImageView>(R.id.island_expanded_play_pause)?.setOnClickListener {
            val e = engine() ?: return@setOnClickListener
            if (e.player.isPlaying) e.pause() else e.play()
            refreshFromPlayer()
            scheduleAutoCollapse()
        }
        view.findViewById<ImageView>(R.id.island_expanded_next)?.setOnClickListener {
            engine()?.skipToNext()
            scheduleAutoCollapse()
        }
        view.findViewById<ImageView>(R.id.island_expanded_prev)?.setOnClickListener {
            engine()?.skipToPrevious()
            scheduleAutoCollapse()
        }
        view.findViewById<ImageView>(R.id.island_expanded_shuffle)?.setOnClickListener {
            val e = engine() ?: return@setOnClickListener
            e.setShuffleMode(!e.player.shuffleModeEnabled)
            scheduleAutoCollapse()
        }
        // Tapping anywhere else on the card collapses it immediately,
        // same as tapping outside per the confirmed spec.
        view.setOnClickListener { collapse() }
        view.findViewById<SeekBar>(R.id.island_expanded_seekbar)?.setOnTouchListener { _, _ -> true }
    }

    // ---- Expand / collapse --------------------------------------------------

    private fun expand() {
        if (isExpanded) return
        isExpanded = true
        addExpandedView()
        removePillView()
        refreshFromPlayer()
        startSeekTicker()
        scheduleAutoCollapse()
    }

    private fun collapse() {
        if (!isExpanded) return
        isExpanded = false
        seekTicker?.cancel()
        autoCollapseJob?.cancel()
        removeExpandedView()
        addPillView()
        refreshFromPlayer()
    }

    private fun scheduleAutoCollapse() {
        autoCollapseJob?.cancel()
        autoCollapseJob = scope.launch {
            delay(AUTO_COLLAPSE_MS)
            collapse()
        }
    }
}
