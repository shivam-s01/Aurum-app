package com.aurum.music

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.TimeInterpolator
import android.animation.ValueAnimator
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.util.LruCache
import android.view.DisplayCutout
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.ViewTreeObserver
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.palette.graphics.Palette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.random.Random

/**
 * Dynamic-Island-style overlay: a small pill sitting on the camera cutout while
 * something plays; tap it (or swipe it down) and it morphs into a full
 * "now playing" card; the card collapses again on tap-outside / tap-on-card /
 * after a few idle seconds.
 *
 * Runs entirely as a WindowManager overlay (SYSTEM_ALERT_WINDOW) and rides on
 * AurumMediaSessionService's foreground lifetime. State comes straight from
 * [AurumMediaSessionService.sharedEngine]'s ExoPlayer.
 *
 * Customization (x / y / width / height / accent) is read from the same
 * "FlutterSharedPreferences" file Dart writes, so it works with no Dart
 * isolate alive. Until the user has positioned the pill themselves - or when
 * they left it within a few dp of the camera - it is locked onto the real
 * camera hole (detected from DisplayCutout).
 *
 * Interaction model of the pill:
 *  - tap / small wobble / quick swipe down  -> open the card
 *  - press and HOLD (~0.4 s, haptic)          -> drag to reposition (magnet on camera)
 *  A plain touch can never move the pill, so it stays exactly where it belongs.
 */
class AurumIslandService : Service() {

    companion object {
        private const val TAG = "AurumIslandService"
        private const val AUTO_COLLAPSE_MS = 6_000L

        // Equalizer bars: scaleY range while playing / resting.
        private const val WAVE_MIN_SCALE = 0.28f
        private const val WAVE_MAX_SCALE = 1.0f
        private const val WAVE_ANIM_MIN_MS = 280L
        private const val WAVE_ANIM_MAX_MS = 460L
        private val WAVE_IDLE_SCALES = floatArrayOf(0.40f, 0.70f, 0.52f)

        private const val PLAY_POP_SCALE = 1.16f
        private const val PLAY_POP_MS = 240L

        private const val EXPAND_MS = 380L
        private const val COLLAPSE_MS = 340L
        private const val CARD_RADIUS_DP = 34f
        private const val ART_RADIUS_DP = 20f
        private const val THUMB_RADIUS_DP = 16f
        private const val THUMB_GAP_DP = 8f

        private const val UP_NEXT_COUNT = 4
        private const val CARD_MAX_WIDTH_DP = 344f
        private const val CARD_SIDE_MARGIN_DP = 12f
        private const val CARD_BASE_TOP_PAD_DP = 20f

        // Invisible touch margin around the visible pill (sides + bottom).
        private const val PILL_HIT_X_DP = 18f
        private const val PILL_HIT_BOTTOM_DP = 16f

        // Pill gestures.
        private const val LONG_PRESS_MS = 380L
        private const val TAP_SLOP_DP = 18f
        private const val SWIPE_EXPAND_DP = 14f
        private const val MAGNET_IN_DP = 16f
        private const val MAGNET_OUT_DP = 28f
        private const val CAMERA_LOCK_DP = 16f

        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_X = "flutter.island_x_dp"
        private const val KEY_Y = "flutter.island_y_dp"
        private const val KEY_WIDTH = "flutter.island_width_dp"
        private const val KEY_HEIGHT = "flutter.island_height_dp"
        private const val KEY_COLOR = "flutter.island_accent_color"

        // shared_preferences (Dart) stores doubles as a prefixed String.
        private const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"

        private const val DEFAULT_X_DP = 0f
        private const val DEFAULT_Y_DP = 8f
        private const val DEFAULT_WIDTH_DP = 101f
        private const val DEFAULT_HEIGHT_DP = 32f
        private const val DEFAULT_ACCENT = 0xFFB89640.toInt()
        private const val DEFAULT_CARD_BASE = 0xFF13121C.toInt()

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        private var activeInstance: AurumIslandService? = null

        /** Re-applies position/size/color to whatever is showing. Main thread only. */
        fun refreshCustomizationNow() {
            activeInstance?.reapplyCustomization()
        }

        /** Hides/shows the overlay while Aurum's own UI is in the foreground. */
        fun setHiddenForForeground(hidden: Boolean) {
            activeInstance?.applyForegroundHidden(hidden)
        }
    }

    private data class IslandPrefs(
        val xDp: Float,
        val yDp: Float,
        val widthDp: Float,
        val heightDp: Float,
        val accentColor: Int,
    )

    /** One "Up next" slot. [queueIndex] indexes the engine's queue; [window]
     *  is a raw ExoPlayer window (used only in shuffle mode). */
    private data class UpNext(
        val exists: Boolean,
        val artUrl: String?,
        val queueIndex: Int,
        val window: Int,
    )

    /** Live rounded-rect the card is currently clipped to while morphing. */
    private class Morph {
        var l = 0f
        var t = 0f
        var r = 0f
        var b = 0f
        var rad = 0f
    }

    private lateinit var windowManager: WindowManager
    private lateinit var prefs: SharedPreferences
    private var pillView: View? = null
    private var expandedView: View? = null
    private var isExpanded = false

    /** Windows that are animating out; tracked so onDestroy can never leak one. */
    private val dyingViews = HashSet<View>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var autoCollapseJob: Job? = null
    private var seekTicker: Job? = null
    private var artworkJob: Job? = null
    private var likeSyncJob: Job? = null
    private var isUserScrubbing = false
    private var refreshPosted = false

    private var lastArtworkUrl: String? = null
    private var lastArtworkBitmap: Bitmap? = null
    private var currentExpandedTint: Int = DEFAULT_CARD_BASE
    private var currentAccent: Int = DEFAULT_ACCENT

    private var playerListener: Player.Listener? = null
    private var listenedPlayer: Player? = null
    private var hiddenForForeground = false

    private val barAnimators = arrayOfNulls<ValueAnimator>(3)
    private var waveBarsRunning = false
    private var thumbPulseAnimator: ValueAnimator? = null

    private var cachedCutout: Rect? = null
    private var upNextSlots: List<UpNext> = emptyList()
    private var thumbSizePx = 0
    private val thumbCache = LruCache<String, Bitmap>(32)
    private val thumbLoading = HashSet<String>()
    private val thumbFailed = HashSet<String>()

    // Visible pill size in px (the pill window itself is bigger: hit margin).
    private var pillW = 0
    private var pillH = 0

    private var cardAnimator: ValueAnimator? = null
    private var cardOpenness = 1f
    private var entranceDone = true

    private val expandInterpolator = PathInterpolator(0.16f, 1f, 0.3f, 1f)
    private val collapseInterpolator = PathInterpolator(0.32f, 0.72f, 0f, 1f)

    // ---- Prefs ------------------------------------------------------------

    private fun rawFloat(key: String): Float? {
        val raw = try { prefs.all[key] } catch (_: Throwable) { null }
        val v: Float? = when (raw) {
            is Number -> raw.toFloat()
            is String -> raw.removePrefix(DOUBLE_PREFIX).toFloatOrNull()
            else -> null
        }
        return if (v == null || v.isNaN() || v.isInfinite()) null else v
    }

    /** True only when the user has really moved the pill. Never-saved and
     *  "Reset to defaults" (x=0, y=8) both count as "not placed", so the pill
     *  stays locked on the camera hole. */
    private fun hasCustomPosition(): Boolean {
        val x = rawFloat(KEY_X)
        val y = rawFloat(KEY_Y)
        if (x == null && y == null) return false
        return abs((x ?: DEFAULT_X_DP) - DEFAULT_X_DP) > 0.5f ||
            abs((y ?: DEFAULT_Y_DP) - DEFAULT_Y_DP) > 0.5f
    }

    private fun readPrefs(): IslandPrefs {
        fun safeFloat(key: String, default: Float): Float = rawFloat(key) ?: default

        val widthDp = safeFloat(KEY_WIDTH, DEFAULT_WIDTH_DP).coerceIn(90f, 360f)
        val heightDp = safeFloat(KEY_HEIGHT, DEFAULT_HEIGHT_DP).coerceIn(32f, 96f)
        var xDp = safeFloat(KEY_X, DEFAULT_X_DP).coerceIn(-500f, 500f)
        var yDp = safeFloat(KEY_Y, DEFAULT_Y_DP).coerceIn(0f, 900f)
        val accent = try {
            (prefs.all[KEY_COLOR] as? Number)?.toInt() ?: DEFAULT_ACCENT
        } catch (_: Throwable) {
            DEFAULT_ACCENT
        }

        // Lock onto the real camera hole when the user never placed the pill,
        // or left it within a few dp of the hole (so "almost centered" is
        // always exactly centered).
        val cam = findCameraCutout()
        if (cam != null) {
            val d = resources.displayMetrics.density
            val sw = resources.displayMetrics.widthPixels
            val camXdp = (cam.exactCenterX() - sw / 2f) / d
            val camYdp = max(0f, cam.exactCenterY() - dpToPx(heightDp) / 2f) / d
            val nearCamera = abs(xDp - camXdp) < CAMERA_LOCK_DP && abs(yDp - camYdp) < CAMERA_LOCK_DP
            if (!hasCustomPosition() || nearCamera) {
                xDp = camXdp
                yDp = camYdp
            }
        }
        return IslandPrefs(xDp, yDp, widthDp, heightDp, accent)
    }

    /** [lockedToCamera] writes the "not placed" defaults so the pill keeps
     *  following the real cutout instead of a frozen pixel offset. */
    private fun savePosition(xPx: Int, yPx: Int, lockedToCamera: Boolean) {
        val d = resources.displayMetrics.density
        val xDp = if (lockedToCamera) DEFAULT_X_DP.toDouble() else (xPx / d).toDouble()
        val yDp = if (lockedToCamera) DEFAULT_Y_DP.toDouble() else (yPx / d).toDouble()
        prefs.edit()
            .putString(KEY_X, DOUBLE_PREFIX + xDp.toString())
            .putString(KEY_Y, DOUBLE_PREFIX + yDp.toString())
            .apply()
    }

    // ---- Camera cutout ----------------------------------------------------

    /** Bounding rect (screen px) of the top camera hole/notch, or null.
     *  Prefers the true hole outline (API 31+ cutout path) so the pill is
     *  centered on the actual hole, then the top bounding rect, then any
     *  cutout rect that sits in the status-bar strip. Punch-holes do NOT
     *  touch the very top edge, so no "top == 0" assumption is made. */
    private fun findCameraCutout(): Rect? {
        cachedCutout?.let { return it }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null

        val fromWindowManager: DisplayCutout? = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                windowManager.currentWindowMetrics.windowInsets.displayCutout
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        }
        val dc: DisplayCutout = fromWindowManager
            ?: try { (pillView ?: expandedView)?.rootWindowInsets?.displayCutout } catch (_: Throwable) { null }
            ?: return null

        val sw = resources.displayMetrics.widthPixels
        val maxTop = dpToPx(72f)
        fun plausible(r: Rect): Boolean = !r.isEmpty && r.top < maxTop && r.width() < sw / 2

        var cam: Rect? = null

        // 1) Exact hole outline (getCutoutPath is API 31; reflection keeps
        //    this compiling against any SDK).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            cam = try {
                val path = DisplayCutout::class.java.getMethod("getCutoutPath").invoke(dc) as? Path
                if (path != null) {
                    val rf = RectF()
                    path.computeBounds(rf, true)
                    Rect(rf.left.roundToInt(), rf.top.roundToInt(), rf.right.roundToInt(), rf.bottom.roundToInt())
                        .takeIf { plausible(it) }
                } else {
                    null
                }
            } catch (_: Throwable) {
                null
            }
        }
        // 2) Top bounding rect.
        if (cam == null) {
            cam = try { dc.boundingRectTop.takeIf { plausible(it) } } catch (_: Throwable) { null }
        }
        // 3) Any plausible cutout rect closest to the screen center.
        if (cam == null) {
            cam = try {
                dc.boundingRects
                    .filter { plausible(it) }
                    .minByOrNull { abs(it.centerX() - sw / 2) }
            } catch (_: Throwable) {
                null
            }
        }
        if (cam != null) cachedCutout = cam
        return cam
    }

    // ---- Service lifecycle ------------------------------------------------

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        isRunning = true
        activeInstance = this
        addPillView()
        ensurePlayerListener()
        refreshFromPlayer()
        if (hiddenForForeground) pillView?.visibility = View.GONE
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        cachedCutout = null
        reapplyCustomization()
    }

    override fun onDestroy() {
        unregisterPlayerListener()
        autoCollapseJob?.cancel()
        seekTicker?.cancel()
        artworkJob?.cancel()
        likeSyncJob?.cancel()
        cardAnimator?.cancel()
        scope.coroutineContext[Job]?.cancel()
        stopWaveBars()
        removePillView()
        removeExpandedView()
        purgeDyingViews()
        lastArtworkBitmap = null
        thumbCache.evictAll()
        thumbLoading.clear()
        isRunning = false
        if (activeInstance === this) activeInstance = null
        super.onDestroy()
    }

    private fun removeWindowSafely(v: View?) {
        if (v == null) return
        try { windowManager.removeView(v) } catch (_: Throwable) {}
    }

    private fun purgeDyingViews() {
        for (v in dyingViews.toList()) {
            v.animate().cancel()
            removeWindowSafely(v)
        }
        dyingViews.clear()
    }

    private fun reapplyCustomization() {
        val snapshot = readPrefs()
        pillView?.let { view ->
            val params = view.layoutParams as? WindowManager.LayoutParams ?: return@let
            applyPillCustomization(view, params, snapshot)
            try { windowManager.updateViewLayout(view, params) } catch (_: Throwable) {}
        }
        expandedView?.let { view ->
            val params = view.layoutParams as? WindowManager.LayoutParams ?: return@let
            applyCardCustomization(view, params, snapshot)
            try { windowManager.updateViewLayout(view, params) } catch (_: Throwable) {}
        }
    }

    private fun applyForegroundHidden(hidden: Boolean) {
        hiddenForForeground = hidden
        val visibility = if (hidden) View.GONE else View.VISIBLE
        if (hidden) {
            cardAnimator?.cancel()
            pillView?.animate()?.cancel()
            expandedView?.animate()?.cancel()
            purgeDyingViews()
        }
        pillView?.visibility = visibility
        expandedView?.visibility = visibility
        if (hidden) {
            autoCollapseJob?.cancel()
            seekTicker?.cancel()
            isExpanded = false
            expandedView?.let { removeWindowSafely(it) }
            expandedView = null
        } else {
            if (!isExpanded && pillView == null) addPillView()
            reapplyCustomization()
            pillView?.let {
                it.animate().cancel()
                it.alpha = 1f
                it.scaleX = 1f
                it.scaleY = 1f
                it.visibility = View.VISIBLE
            }
            refreshFromPlayer()
        }
    }

    // ---- Player state sync ------------------------------------------------

    private fun ensurePlayerListener() {
        val player = AurumMediaSessionService.sharedEngine?.player ?: return
        if (playerListener != null && listenedPlayer === player) return
        unregisterPlayerListener()
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) { postRefresh() }
            override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) { postRefresh() }
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) { postRefresh() }
            override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) { postRefresh() }
            override fun onTimelineChanged(timeline: Timeline, reason: Int) { postRefresh() }
            override fun onPlaybackStateChanged(playbackState: Int) { postRefresh() }
        }
        player.addListener(listener)
        playerListener = listener
        listenedPlayer = player
    }

    private fun unregisterPlayerListener() {
        playerListener?.let { listenedPlayer?.removeListener(it) }
        playerListener = null
        listenedPlayer = null
    }

    /** Coalesces bursts of player events (queue resolves fire many) into one refresh. */
    private fun postRefresh() {
        if (refreshPosted) return
        refreshPosted = true
        scope.launch {
            refreshPosted = false
            refreshFromPlayer()
        }
    }

    private fun setTextIfChanged(tv: TextView?, value: String) {
        if (tv != null && tv.text?.toString() != value) tv.text = value
    }

    private fun refreshFromPlayer() {
        ensurePlayerListener()
        val engine = AurumMediaSessionService.sharedEngine
        val player = engine?.player
        val metadata = player?.mediaMetadata
        val hasSong = player != null && player.mediaItemCount > 0 &&
            !metadata?.title?.toString().isNullOrEmpty()

        if (!hasSong || player == null) {
            stopWaveBars()
            return
        }

        val title = metadata?.title?.toString() ?: ""
        val artist = metadata?.artist?.toString() ?: ""
        val artworkUri = metadata?.artworkUri?.toString()
        val isPlaying = player.isPlaying

        if (pillView != null) startOrStopWaveBars(isPlaying)

        expandedView?.let { view ->
            view.findViewById<TextView>(R.id.island_expanded_title)?.let {
                setTextIfChanged(it, title)
                it.isSelected = true
            }
            setTextIfChanged(view.findViewById<TextView>(R.id.island_expanded_artist), artist)
            setPlayPauseState(view, isPlaying, animate = false)
            updateSeekbar(player)
            updateQueueThumbnails(player)
            updateLikeIcon(view)
            updateShuffleIcon(view, player.shuffleModeEnabled)
            updateRouteIcon(view)
        }

        if (artworkUri != lastArtworkUrl) {
            lastArtworkUrl = artworkUri
            loadArtwork(artworkUri)
        }
    }

    private fun updateSeekbar(player: Player?) {
        if (player == null || isUserScrubbing) return
        val view = expandedView ?: return
        val duration = player.duration.takeIf { it > 0 } ?: 1L
        val position = player.currentPosition.coerceIn(0L, duration)
        view.findViewById<SeekBar>(R.id.island_expanded_seekbar)?.apply {
            if (max != 1000) max = 1000
            progress = ((position.toDouble() / duration.toDouble()) * 1000).toInt()
        }
        setTextIfChanged(view.findViewById<TextView>(R.id.island_expanded_position), formatMs(position))
        setTextIfChanged(
            view.findViewById<TextView>(R.id.island_expanded_duration),
            if (player.duration > 0) formatMs(player.duration) else "0:00",
        )
    }

    private fun formatMs(ms: Long): String {
        val totalSec = ms / 1000
        return String.format(Locale.US, "%d:%02d", totalSec / 60, totalSec % 60)
    }

    private fun startSeekTicker() {
        seekTicker?.cancel()
        seekTicker = scope.launch {
            while (isExpanded) {
                updateSeekbar(AurumMediaSessionService.sharedEngine?.player)
                delay(250)
            }
        }
    }

    // ---- Small icon states ------------------------------------------------

    private fun updateLikeIcon(view: View) {
        val engine = AurumMediaSessionService.sharedEngine ?: return
        setLikeIcon(view, engine.isCurrentSongLiked(), animate = false)
    }

    private fun setLikeIcon(view: View, liked: Boolean, animate: Boolean) {
        val icon = view.findViewById<ImageView>(R.id.island_expanded_like) ?: return
        icon.setImageResource(if (liked) R.drawable.ic_like_filled else R.drawable.ic_like_outline)
        icon.setColorFilter(if (liked) currentAccent else Color.WHITE)
        if (!animate) return
        icon.animate().cancel()
        icon.scaleX = 0.8f
        icon.scaleY = 0.8f
        icon.animate()
            .scaleX(1f).scaleY(1f)
            .setDuration(260L)
            .setInterpolator(OvershootInterpolator(3f))
            .start()
    }

    private fun updateShuffleIcon(view: View, on: Boolean) {
        view.findViewById<ImageView>(R.id.island_expanded_shuffle)?.setColorFilter(
            if (on) currentAccent else Color.argb(0x8C, 255, 255, 255)
        )
    }

    private fun updateRouteIcon(view: View) {
        val icon = view.findViewById<ImageView>(R.id.island_expanded_route_icon) ?: return
        val engine = AurumMediaSessionService.sharedEngine
        if (engine?.isCasting() == true) {
            icon.setImageResource(R.drawable.ic_island_speaker)
            icon.alpha = 1f
            return
        }
        val isBluetooth = try {
            val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            am?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.any {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
            } ?: false
        } catch (_: Throwable) {
            false
        }
        icon.setImageResource(if (isBluetooth) R.drawable.ic_island_bluetooth else R.drawable.ic_island_speaker)
        icon.alpha = 0.7f
    }

    private fun setPlayPauseState(view: View, isPlaying: Boolean, animate: Boolean) {
        val icon = view.findViewById<ImageView>(R.id.island_expanded_play_pause) ?: return
        icon.setImageResource(if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play)
        if (!animate) return
        icon.animate().cancel()
        icon.scaleX = 1f
        icon.scaleY = 1f
        icon.animate()
            .scaleX(PLAY_POP_SCALE).scaleY(PLAY_POP_SCALE)
            .setDuration(PLAY_POP_MS / 2)
            .withEndAction {
                icon.animate().scaleX(1f).scaleY(1f).setDuration(PLAY_POP_MS / 2).start()
            }
            .start()
    }

    // ---- Equalizer + pill artwork pulse ----------------------------------

    private fun dpToPx(dp: Float): Int = (dp * resources.displayMetrics.density).roundToInt()

    private fun pillBody(root: View): View? = root.findViewById<View>(R.id.island_pill_body)

    private fun pillBars(root: View): List<View?> = listOf(
        root.findViewById<View>(R.id.island_wave_bar_1),
        root.findViewById<View>(R.id.island_wave_bar_2),
        root.findViewById<View>(R.id.island_wave_bar_3),
    )

    private fun setIdleBars(root: View) {
        pillBars(root).forEachIndexed { i, bar ->
            bar?.scaleY = WAVE_IDLE_SCALES[i]
        }
    }

    private fun startOrStopWaveBars(isPlaying: Boolean) {
        val root = pillView ?: return
        if (isPlaying) {
            if (waveBarsRunning) return
            waveBarsRunning = true
            pillBars(root).forEachIndexed { i, bar ->
                if (bar != null) runBar(i, bar, WAVE_IDLE_SCALES[i])
            }
            startThumbPulse(root)
        } else {
            stopWaveBars()
        }
    }

    private fun runBar(index: Int, bar: View, from: Float) {
        if (!waveBarsRunning) return
        val to = WAVE_MIN_SCALE + Random.nextFloat() * (WAVE_MAX_SCALE - WAVE_MIN_SCALE)
        val anim = ValueAnimator.ofFloat(from, to).apply {
            duration = Random.nextLong(WAVE_ANIM_MIN_MS, WAVE_ANIM_MAX_MS + 1)
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { bar.scaleY = it.animatedValue as Float }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false
                override fun onAnimationCancel(animation: Animator) { cancelled = true }
                override fun onAnimationEnd(animation: Animator) {
                    if (!cancelled) runBar(index, bar, to)
                }
            })
        }
        barAnimators[index] = anim
        anim.start()
    }

    private fun startThumbPulse(pillRoot: View) {
        thumbPulseAnimator?.cancel()
        val thumb = pillRoot.findViewById<ImageView>(R.id.island_pill_artwork) ?: return
        thumb.scaleX = 1f
        thumb.scaleY = 1f
        thumbPulseAnimator = ValueAnimator.ofFloat(1f, 1.05f).apply {
            duration = 1000L
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener {
                val s = it.animatedValue as Float
                thumb.scaleX = s
                thumb.scaleY = s
            }
            start()
        }
    }

    private fun stopWaveBars() {
        waveBarsRunning = false
        for (i in barAnimators.indices) {
            barAnimators[i]?.cancel()
            barAnimators[i] = null
        }
        thumbPulseAnimator?.cancel()
        thumbPulseAnimator = null
        val root = pillView ?: return
        root.findViewById<ImageView>(R.id.island_pill_artwork)?.apply { scaleX = 1f; scaleY = 1f }
        setIdleBars(root)
    }

    // ---- Shape helpers (outline clipping = identical shapes, zero bitmap work) ----

    private fun clipCircle(v: View) {
        v.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setOval(0, 0, view.width, view.height)
            }
        }
        v.clipToOutline = true
    }

    private fun clipRounded(v: View, radiusDp: Float) {
        val r = dpToPx(radiusDp).toFloat()
        v.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, r)
            }
        }
        v.clipToOutline = true
    }

    private fun setForegroundCompat(v: View, resId: Int?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        v.foreground = if (resId == null) null else getDrawable(resId)
    }

    // ---- Up-next thumbnails -----------------------------------------------

    private fun computeUpNext(player: Player): List<UpNext> {
        val none = UpNext(false, null, -1, -1)
        val out = ArrayList<UpNext>(UP_NEXT_COUNT)

        if (player.shuffleModeEnabled) {
            // Shuffle plays ExoPlayer's own order, not the queue order.
            val tl = player.currentTimeline
            var w = player.currentMediaItemIndex
            for (i in 0 until UP_NEXT_COUNT) {
                w = if (w == C.INDEX_UNSET || tl.isEmpty) C.INDEX_UNSET
                else tl.getNextWindowIndex(w, Player.REPEAT_MODE_OFF, true)
                if (w == C.INDEX_UNSET || w >= player.mediaItemCount) {
                    out.add(none)
                } else {
                    val art = player.getMediaItemAt(w).mediaMetadata.artworkUri?.toString()
                    out.add(UpNext(true, art, -1, w))
                }
            }
            return out
        }

        val engine = AurumMediaSessionService.sharedEngine
        val queue = engine?.currentQueue().orEmpty()
        val base = (engine?.currentSongIndex() ?: player.currentMediaItemIndex) + 1
        for (i in 0 until UP_NEXT_COUNT) {
            val idx = base + i
            if (queue.isNotEmpty()) {
                val song = queue.getOrNull(idx)
                out.add(
                    if (song != null) UpNext(true, song.artworkUrl.takeIf { it.isNotEmpty() }, idx, -1)
                    else none
                )
            } else if (idx < player.mediaItemCount) {
                val art = player.getMediaItemAt(idx).mediaMetadata.artworkUri?.toString()
                out.add(UpNext(true, art, -1, idx))
            } else {
                out.add(none)
            }
        }
        return out
    }

    private fun thumbIds() = listOf(
        R.id.island_queue_thumb_1,
        R.id.island_queue_thumb_2,
        R.id.island_queue_thumb_3,
        R.id.island_queue_thumb_4,
    )

    private fun updateQueueThumbnails(player: Player) {
        val view = expandedView ?: return
        val slots = computeUpNext(player)
        upNextSlots = slots
        for ((i, id) in thumbIds().withIndex()) {
            val iv = view.findViewById<ImageView>(id) ?: continue
            bindThumb(iv, slots[i])
        }
    }

    private fun bindThumb(iv: ImageView, slot: UpNext) {
        if (!slot.exists) {
            iv.tag = null
            iv.setImageDrawable(null)
            iv.setBackgroundResource(R.drawable.island_thumb_placeholder)
            iv.alpha = 0.28f
            iv.isClickable = false
            setForegroundCompat(iv, null)
            return
        }
        iv.alpha = 1f
        iv.isClickable = true
        setForegroundCompat(iv, R.drawable.island_thumb_fg)
        val url = slot.artUrl
        if (url.isNullOrEmpty()) {
            iv.tag = null
            iv.setImageDrawable(null)
            iv.setBackgroundResource(R.drawable.island_thumb_placeholder)
            return
        }
        val size = if (thumbSizePx > 0) thumbSizePx else dpToPx(64f)
        val key = "$url@$size"
        if (iv.tag == key && iv.drawable != null) return // already showing this one
        iv.tag = key
        val cached = thumbCache.get(key)
        if (cached != null && !cached.isRecycled) {
            iv.background = null
            iv.setImageBitmap(cached)
            return
        }
        iv.setImageDrawable(null)
        iv.setBackgroundResource(R.drawable.island_thumb_placeholder)
        loadThumb(key, url, size)
    }

    private fun loadThumb(key: String, url: String, size: Int) {
        if (key in thumbFailed || key in thumbLoading) return
        thumbLoading.add(key)
        scope.launch {
            val bmp = withContext(Dispatchers.IO) { downloadBitmap(url, size) }
            thumbLoading.remove(key)
            if (bmp == null) {
                thumbFailed.add(key)
                return@launch
            }
            thumbCache.put(key, bmp)
            val view = expandedView ?: return@launch
            for (id in thumbIds()) {
                val iv = view.findViewById<ImageView>(id) ?: continue
                if (iv.tag == key) {
                    iv.background = null
                    iv.setImageBitmap(bmp)
                }
            }
        }
    }

    private fun onUpNextTapped(slot: Int) {
        val item = upNextSlots.getOrNull(slot) ?: return
        if (!item.exists) return
        val engine = AurumMediaSessionService.sharedEngine ?: return
        if (item.queueIndex >= 0) {
            scope.launch {
                try {
                    engine.skipToQueueItemAwaitable(item.queueIndex)
                } catch (e: Throwable) {
                    Log.w(TAG, "skipToQueueItem failed: ${e.message}")
                }
            }
        } else if (item.window >= 0) {
            val p = engine.player
            if (item.window < p.mediaItemCount) {
                p.seekTo(item.window, 0L)
                p.play()
            }
        }
        // The engine can take a beat to move (fresh resolve); re-sync twice.
        scope.launch {
            delay(350)
            refreshFromPlayer()
            delay(800)
            refreshFromPlayer()
        }
        scheduleAutoCollapse()
    }

    /** Makes the four up-next tiles identical squares that fill the card row. */
    private fun sizeQueueThumbs(view: View, cardWidthPx: Int) {
        val inner = cardWidthPx - view.paddingLeft - view.paddingRight
        val gap = dpToPx(THUMB_GAP_DP)
        val size = ((inner - gap * (UP_NEXT_COUNT - 1)) / UP_NEXT_COUNT).coerceAtLeast(dpToPx(40f))
        thumbSizePx = size
        for ((i, id) in thumbIds().withIndex()) {
            val iv = view.findViewById<ImageView>(id) ?: continue
            iv.layoutParams = LinearLayout.LayoutParams(size, size).apply {
                marginEnd = if (i < UP_NEXT_COUNT - 1) gap else 0
            }
            clipRounded(iv, THUMB_RADIUS_DP)
            iv.isClickable = false
        }
    }

    // ---- Artwork ----------------------------------------------------------

    private fun setArt(iv: ImageView, bmp: Bitmap, fade: Boolean) {
        iv.background = null
        iv.setImageBitmap(bmp)
        if (fade) {
            iv.animate().cancel()
            iv.alpha = 0.3f
            iv.animate().alpha(1f).setDuration(200L).start()
        }
    }

    private fun applyArtworkTo(view: View, fade: Boolean = false) {
        val bmp = lastArtworkBitmap ?: return
        view.findViewById<ImageView>(R.id.island_pill_artwork)?.let { setArt(it, bmp, fade) }
        view.findViewById<ImageView>(R.id.island_expanded_artwork)?.let { setArt(it, bmp, fade) }
    }

    private fun loadArtwork(urlString: String?) {
        artworkJob?.cancel()
        if (urlString.isNullOrEmpty()) {
            lastArtworkBitmap = null
            pillView?.findViewById<ImageView>(R.id.island_pill_artwork)?.apply {
                setImageDrawable(null)
                setBackgroundResource(R.drawable.island_art_circle_placeholder)
            }
            expandedView?.findViewById<ImageView>(R.id.island_expanded_artwork)?.apply {
                setImageDrawable(null)
                setBackgroundResource(R.drawable.island_thumb_placeholder)
            }
            return
        }
        artworkJob = scope.launch {
            val bmp = withContext(Dispatchers.IO) { downloadBitmap(urlString, 360) }
            if (bmp == null) {
                // Allow a retry on the next refresh instead of staying blank.
                if (lastArtworkUrl == urlString) lastArtworkUrl = null
                return@launch
            }
            if (urlString != lastArtworkUrl) return@launch // a newer song took over
            // Old bitmap is NOT recycled by hand: a view may still be drawing it.
            lastArtworkBitmap = bmp
            pillView?.let { applyArtworkTo(it, fade = true) }
            expandedView?.let { applyArtworkTo(it, fade = true) }
            tintExpandedBackground(bmp)
        }
    }

    /** Downloads/decodes at the smallest power-of-two sample that still gives
     *  at least [targetPx] on the short side (sharp, but not wasteful). */
    private fun downloadBitmap(urlString: String, targetPx: Int): Bitmap? {
        return try {
            val uri = Uri.parse(urlString)
            val bytes = if (uri.scheme == "content") {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } else {
                val conn = URL(urlString).openConnection().apply {
                    connectTimeout = 6_000
                    readTimeout = 8_000
                }
                conn.getInputStream().use { it.readBytes() }
            } ?: return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val shortSide = min(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (shortSide / (sample * 2) >= targetPx) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        } catch (e: Throwable) {
            Log.w(TAG, "downloadBitmap failed: ${e.message}")
            null
        }
    }

    // ---- Customization: position / size / color ---------------------------

    /**
     * Sizes the (bigger-than-visible) pill window and the black capsule inside
     * it. The window is centered on the capsule horizontally and shares its
     * top edge; the extra margin is only on the sides and bottom, so the
     * capsule's own position is exactly [IslandPrefs.xDp]/[IslandPrefs.yDp].
     */
    private fun applyPillCustomization(root: View, params: WindowManager.LayoutParams, s: IslandPrefs) {
        currentAccent = s.accentColor
        val m = resources.displayMetrics
        val pw = dpToPx(s.widthDp)
        val ph = dpToPx(s.heightDp)
        val hx = dpToPx(PILL_HIT_X_DP)
        val hb = dpToPx(PILL_HIT_BOTTOM_DP)
        val maxX = ((m.widthPixels - pw) / 2).coerceAtLeast(0)

        pillW = pw
        pillH = ph
        params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        params.x = dpToPx(s.xDp).coerceIn(-maxX, maxX)
        params.y = dpToPx(s.yDp).coerceIn(0, (m.heightPixels - ph).coerceAtLeast(0))
        params.width = pw + hx * 2
        params.height = ph + hb

        pillBody(root)?.let { body ->
            val lp = (body.layoutParams as? FrameLayout.LayoutParams) ?: FrameLayout.LayoutParams(pw, ph)
            val changed = lp.width != pw || lp.height != ph
            lp.width = pw
            lp.height = ph
            lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            if (changed || body.layoutParams == null) body.layoutParams = lp

            // Artwork + equalizer slots are the same square, mirrored on the
            // two caps, so the content stays concentric with the capsule.
            val slot = dpToPx((s.heightDp - 8f).coerceIn(22f, 44f))
            val inset = ((ph - slot) / 2).coerceAtLeast(dpToPx(3f))
            body.setPadding(inset, 0, inset, 0)
            (body.background?.mutate() as? GradientDrawable)?.cornerRadius = ph / 2f
            resizeSquare(root.findViewById<View>(R.id.island_pill_artwork), slot)
            resizeSquare(root.findViewById<View>(R.id.island_pill_wave_slot), slot)
        }

        pillBars(root).forEach { bar ->
            (bar?.background?.mutate() as? GradientDrawable)?.setColor(s.accentColor)
        }
        root.scaleX = 1f
        root.scaleY = 1f
    }

    private fun resizeSquare(v: View?, sizePx: Int) {
        if (v == null) return
        val lp = v.layoutParams ?: return
        if (lp.width != sizePx || lp.height != sizePx) {
            lp.width = sizePx
            lp.height = sizePx
            v.layoutParams = lp
        }
    }

    private fun applyCardCustomization(root: View, params: WindowManager.LayoutParams, s: IslandPrefs) {
        currentAccent = s.accentColor
        val metrics = resources.displayMetrics
        params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        // The card always opens centered, like a real full-player card, with
        // its top edge exactly where the pill's top edge was.
        params.x = 0
        params.y = dpToPx(s.yDp)
            .coerceIn(0, (metrics.heightPixels - dpToPx(380f)).coerceAtLeast(0))
        tintBackground(root.background, s.accentColor)

        val accent = s.accentColor
        root.findViewById<SeekBar>(R.id.island_expanded_seekbar)?.let {
            it.progressTintList = ColorStateList.valueOf(accent)
        }
        root.findViewById<TextView>(R.id.island_expanded_wordmark)?.setTextColor(accent)
        updateShuffleIcon(root, AurumMediaSessionService.sharedEngine?.player?.shuffleModeEnabled == true)
        updateLikeIcon(root)
    }

    private fun tintBackground(bg: android.graphics.drawable.Drawable?, accent: Int) {
        val gd = bg?.mutate() as? GradientDrawable ?: return
        gd.setStroke(dpToPx(1f), Color.argb(0x30, Color.red(accent), Color.green(accent), Color.blue(accent)))
    }

    /** Soft 3-stop card gradient: dark top (melts into the camera), colored
     *  middle, deeper bottom. */
    private fun setCardColors(bg: GradientDrawable, base: Int) {
        bg.orientation = GradientDrawable.Orientation.TOP_BOTTOM
        bg.setColors(
            intArrayOf(
                ColorUtils.blendARGB(base, Color.BLACK, 0.42f),
                base,
                ColorUtils.blendARGB(base, Color.BLACK, 0.30f),
            )
        )
    }

    /** Art-adaptive card color: sampled from the cover, darkened until white
     *  text is comfortably readable. */
    private suspend fun tintExpandedBackground(bitmap: Bitmap) {
        val swatchColor = withContext(Dispatchers.Default) {
            val palette = Palette.from(bitmap).generate()
            (palette.vibrantSwatch ?: palette.mutedSwatch ?: palette.dominantSwatch)?.rgb
        } ?: return
        var tinted = ColorUtils.blendARGB(DEFAULT_CARD_BASE, swatchColor, 0.78f)
        var guard = 0
        while (ColorUtils.calculateLuminance(tinted) > 0.22 && guard < 8) {
            tinted = ColorUtils.blendARGB(tinted, Color.BLACK, 0.12f)
            guard++
        }
        val fromColor = currentExpandedTint
        currentExpandedTint = tinted
        val view = expandedView ?: return
        // While the card is morphing, the morph reads currentExpandedTint itself.
        if (cardAnimator?.isRunning == true) return
        val bg = view.background?.mutate() as? GradientDrawable ?: return
        ValueAnimator.ofArgb(fromColor, tinted).apply {
            duration = 260L
            interpolator = DecelerateInterpolator()
            addUpdateListener { anim ->
                if (!view.isAttachedToWindow) { cancel(); return@addUpdateListener }
                setCardColors(bg, anim.animatedValue as Int)
            }
            start()
        }
    }

    // ---- Overlay windows ---------------------------------------------------

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

    /** Overlay params that may sit truly at the top (over status bar AND the
     *  camera cutout) and always receive touches there. */
    private fun baseParams(extraFlags: Int = 0): WindowManager.LayoutParams {
        val p = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                extraFlags,
            PixelFormat.TRANSLUCENT,
        )
        p.title = "AurumIsland"
        p.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            p.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            p.setFitInsetsTypes(0)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            p.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        return p
    }

    private fun attachPressScale(v: View, pressed: Float = 0.92f) {
        v.setOnTouchListener { view, e ->
            if (view.isClickable) {
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN ->
                        view.animate().scaleX(pressed).scaleY(pressed).setDuration(80L).start()
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                        view.animate().scaleX(1f).scaleY(1f).setDuration(140L).start()
                }
            }
            false // never consume: the click must still fire
        }
    }

    /**
     * Pill touch:
     *  - tap, a small wobble, a quick swipe down, or a system-cancelled quick
     *    press  -> expand (forgiving on purpose: the pill lives in the
     *    status-bar strip where fingers roll and the system may steal a gesture);
     *  - press and hold -> drag to reposition, with a magnet onto the camera.
     * A plain touch can never move the pill.
     */
    private fun attachPillTouch(root: View, params: WindowManager.LayoutParams) {
        val tapSlop = dpToPx(TAP_SLOP_DP)
        val swipeDist = dpToPx(SWIPE_EXPAND_DP)
        val magnetIn = dpToPx(MAGNET_IN_DP)
        val magnetOut = dpToPx(MAGNET_OUT_DP)

        var downX = 0f
        var downY = 0f
        var lastX = 0f
        var lastY = 0f
        var anchorX = 0f
        var anchorY = 0f
        var startX = 0
        var startY = 0
        var downTime = 0L
        var dragging = false
        var handled = false   // expand already fired for this gesture
        var wandered = false  // moved too far to still count as a tap
        var snappedX = false
        var snappedY = false
        var pressJob: Job? = null

        fun releaseScale() {
            pillBody(root)?.animate()?.scaleX(1f)?.scaleY(1f)?.setDuration(140L)?.start()
        }

        fun dragTo() {
            val m = resources.displayMetrics
            val maxX = ((m.widthPixels - pillW) / 2).coerceAtLeast(0)
            var nx = (startX + (lastX - anchorX).toInt()).coerceIn(-maxX, maxX)
            var ny = (startY + (lastY - anchorY).toInt()).coerceIn(0, (m.heightPixels - pillH).coerceAtLeast(0))

            // Magnet: camera hole if we know it, else screen center.
            val cam = findCameraCutout()
            val targetX = if (cam != null) (cam.exactCenterX() - m.widthPixels / 2f).roundToInt() else 0
            val nowX = abs(nx - targetX) < (if (snappedX) magnetOut else magnetIn)
            if (nowX) nx = targetX
            var nowY = false
            if (cam != null) {
                val targetY = max(0, (cam.exactCenterY() - pillH / 2f).roundToInt())
                nowY = abs(ny - targetY) < (if (snappedY) magnetOut else magnetIn)
                if (nowY) ny = targetY
            }
            if ((nowX && !snappedX) || (nowY && !snappedY)) {
                root.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            }
            snappedX = nowX
            snappedY = nowY

            params.x = nx
            params.y = ny
            try { windowManager.updateViewLayout(root, params) } catch (_: Throwable) {}
        }

        fun finishDrag() {
            val locked = findCameraCutout() != null && snappedX && snappedY
            savePosition(params.x, params.y, locked)
        }

        root.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX
                    downY = e.rawY
                    lastX = downX
                    lastY = downY
                    startX = params.x
                    startY = params.y
                    downTime = e.eventTime
                    dragging = false
                    handled = false
                    wandered = false
                    snappedX = false
                    snappedY = false
                    pillBody(v)?.animate()?.scaleX(0.95f)?.scaleY(0.95f)?.setDuration(90L)?.start()
                    pressJob?.cancel()
                    pressJob = scope.launch {
                        delay(LONG_PRESS_MS)
                        if (!handled && !wandered) {
                            dragging = true
                            autoCollapseJob?.cancel()
                            startX = params.x
                            startY = params.y
                            anchorX = lastX
                            anchorY = lastY
                            v.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            pillBody(v)?.animate()?.scaleX(1.06f)?.scaleY(1.06f)?.setDuration(140L)?.start()
                        }
                    }
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    lastX = e.rawX
                    lastY = e.rawY
                    if (dragging) {
                        dragTo()
                    } else if (!handled) {
                        val dx = lastX - downX
                        val dy = lastY - downY
                        if (dy > swipeDist && dy > abs(dx)) {
                            handled = true
                            pressJob?.cancel()
                            releaseScale()
                            expand()
                        } else if (abs(dx) > tapSlop || abs(dy) > tapSlop) {
                            wandered = true
                            pressJob?.cancel()
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    pressJob?.cancel()
                    releaseScale()
                    if (dragging) {
                        finishDrag()
                    } else if (!handled && !wandered) {
                        handled = true
                        expand()
                    }
                    dragging = false
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    pressJob?.cancel()
                    releaseScale()
                    if (dragging) {
                        finishDrag()
                    } else if (!handled && !wandered && e.eventTime - downTime < 700L) {
                        handled = true
                        expand()
                    }
                    dragging = false
                    true
                }
                else -> false
            }
        }
    }

    private fun addPillView() {
        if (pillView != null) return
        val view = LayoutInflater.from(this).inflate(R.layout.island_pill, null)
        val snapshot = readPrefs()
        val params = baseParams()
        applyPillCustomization(view, params, snapshot)
        setIdleBars(view)
        view.findViewById<ImageView>(R.id.island_pill_artwork)?.let { clipCircle(it) }
        applyArtworkTo(view)

        view.setOnClickListener { expand() } // accessibility / keyboard path
        attachPillTouch(view, params)

        try {
            windowManager.addView(view, params)
            pillView = view
            view.isHapticFeedbackEnabled = true
            if (hiddenForForeground) view.visibility = View.GONE
            // On Android < 11 the cutout is only known once a window is up;
            // re-align to the camera then (only if the user hasn't placed it).
            if (cachedCutout == null) {
                for (delayMs in longArrayOf(200L, 700L)) {
                    view.postDelayed({
                        if (pillView === view && cachedCutout == null && findCameraCutout() != null) {
                            reapplyCustomization()
                        }
                    }, delayMs)
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "addPillView failed: ${e.message}", e)
        }
    }

    private fun removePillView() {
        stopWaveBars()
        removeWindowSafely(pillView)
        pillView = null
    }

    private fun addExpandedView() {
        if (expandedView != null) return
        val view = LayoutInflater.from(this).inflate(R.layout.island_expanded, null)
        val snapshot = readPrefs()

        val params = baseParams(extraFlags = WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH)
        val cardWidth = min(
            dpToPx(CARD_MAX_WIDTH_DP),
            resources.displayMetrics.widthPixels - dpToPx(CARD_SIDE_MARGIN_DP * 2),
        )
        params.width = cardWidth
        applyCardCustomization(view, params, snapshot)

        // Keep the header clear of the camera hole when the card sits at the top.
        val basePad = dpToPx(CARD_BASE_TOP_PAD_DP)
        val cam = findCameraCutout()
        val topPad = if (cam != null && params.y < cam.bottom) {
            max(basePad, cam.bottom - params.y + dpToPx(10f))
        } else {
            basePad
        }
        view.setPadding(view.paddingLeft, topPad, view.paddingRight, view.paddingBottom)

        sizeQueueThumbs(view, cardWidth)
        view.findViewById<ImageView>(R.id.island_expanded_artwork)?.let {
            clipRounded(it, ART_RADIUS_DP)
            setForegroundCompat(it, R.drawable.island_art_fg)
        }
        wireExpandedControls(view)
        applyArtworkTo(view)
        (view.background?.mutate() as? GradientDrawable)?.let { setCardColors(it, currentExpandedTint) }

        try {
            windowManager.addView(view, params)
            expandedView = view
            view.isHapticFeedbackEnabled = true
        } catch (e: Throwable) {
            Log.e(TAG, "addExpandedView failed: ${e.message}", e)
        }
    }

    private fun removeExpandedView() {
        removeWindowSafely(expandedView)
        expandedView = null
    }

    private fun wireExpandedControls(view: View) {
        val engine = { AurumMediaSessionService.sharedEngine }

        view.findViewById<ImageView>(R.id.island_expanded_play_pause)?.let { btn ->
            btn.isHapticFeedbackEnabled = true
            attachPressScale(btn, 0.94f)
            btn.setOnClickListener {
                val e = engine() ?: return@setOnClickListener
                val nowPlaying = !e.player.isPlaying
                if (nowPlaying) e.play() else e.pause()
                setPlayPauseState(view, nowPlaying, animate = true)
                tick(btn)
                scheduleAutoCollapse()
            }
        }
        view.findViewById<ImageView>(R.id.island_expanded_next)?.let { b ->
            attachPressScale(b)
            b.setOnClickListener {
                engine()?.skipToNext()
                tick(b)
                scheduleAutoCollapse()
            }
        }
        view.findViewById<ImageView>(R.id.island_expanded_prev)?.let { b ->
            attachPressScale(b)
            b.setOnClickListener {
                engine()?.skipToPrevious()
                tick(b)
                scheduleAutoCollapse()
            }
        }
        view.findViewById<ImageView>(R.id.island_expanded_shuffle)?.let { b ->
            attachPressScale(b)
            b.setOnClickListener {
                val e = engine() ?: return@setOnClickListener
                val target = !e.player.shuffleModeEnabled
                e.setShuffleMode(target)
                updateShuffleIcon(view, target)
                updateQueueThumbnails(e.player)
                tick(b)
                scheduleAutoCollapse()
            }
        }
        view.findViewById<ImageView>(R.id.island_expanded_like)?.let { likeBtn ->
            likeBtn.isHapticFeedbackEnabled = true
            attachPressScale(likeBtn)
            likeBtn.setOnClickListener {
                val e = engine() ?: return@setOnClickListener
                val target = !e.isCurrentSongLiked()
                e.triggerLikeToggle()
                setLikeIcon(view, target, animate = true) // optimistic
                tick(likeBtn)
                scheduleAutoCollapse()
                // Dart flips the authoritative state a beat later; re-sync once.
                likeSyncJob?.cancel()
                likeSyncJob = scope.launch {
                    delay(1_500)
                    expandedView?.let { updateLikeIcon(it) }
                }
            }
        }

        // Up-next tiles: tap plays that exact song.
        for ((i, id) in thumbIds().withIndex()) {
            view.findViewById<ImageView>(id)?.let { thumb ->
                attachPressScale(thumb, 0.92f)
                thumb.setOnClickListener {
                    tick(thumb)
                    onUpNextTapped(i)
                }
                thumb.isClickable = false // enabled per slot in bindThumb
            }
        }

        view.findViewById<SeekBar>(R.id.island_expanded_seekbar)?.setOnSeekBarChangeListener(
            object : SeekBar.OnSeekBarChangeListener {
                override fun onStartTrackingTouch(seekBar: SeekBar) {
                    isUserScrubbing = true
                    autoCollapseJob?.cancel()
                }
                override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    val player = engine()?.player ?: return
                    val duration = player.duration.takeIf { it > 0 } ?: return
                    val targetMs = (duration * (progress / 1000.0)).toLong()
                    setTextIfChanged(view.findViewById<TextView>(R.id.island_expanded_position), formatMs(targetMs))
                }
                override fun onStopTrackingTouch(seekBar: SeekBar) {
                    val player = engine()?.player
                    val duration = player?.duration?.takeIf { it > 0 }
                    if (player != null && duration != null) {
                        player.seekTo((duration * (seekBar.progress / 1000.0)).toLong())
                    }
                    isUserScrubbing = false
                    scheduleAutoCollapse()
                }
            }
        )

        // Tap on the card body, or anywhere outside it, collapses it.
        view.setOnClickListener { collapse() }
        view.setOnTouchListener { _, e ->
            if (e.actionMasked == MotionEvent.ACTION_OUTSIDE) {
                collapse()
                true
            } else {
                false
            }
        }
    }

    // ---- Expand / collapse ------------------------------------------------

    private fun tick(view: View) {
        view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    }

    private fun lerp(a: Float, b: Float, t: Float): Float = a + (b - a) * t

    /**
     * True morph: the fully laid-out card is revealed through a rounded-rect
     * mask that grows from the exact pill rectangle to the full card (and back).
     * Content is never squashed, corners stay round, and the card color fades
     * from the pill's pure black into the art tint - so it reads as the pill
     * itself stretching open. [from]/[to] are "openness" values (0 = pill, 1 = card).
     */
    private fun animateOpenness(
        view: View,
        pillRect: RectF,
        cardRect: RectF,
        pillRadius: Float,
        cardRadius: Float,
        from: Float,
        to: Float,
        durationMs: Long,
        timing: TimeInterpolator,
        onEnd: () -> Unit,
    ) {
        cardAnimator?.cancel()
        val closing = to < from
        val m = Morph()
        val bg = view.background?.mutate() as? GradientDrawable
        view.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(v: View, outline: Outline) {
                outline.setRoundRect(m.l.roundToInt(), m.t.roundToInt(), m.r.roundToInt(), m.b.roundToInt(), m.rad)
            }
        }
        view.clipToOutline = true

        fun render(g: Float) {
            cardOpenness = g
            m.l = lerp(pillRect.left, cardRect.left, g)
            m.t = lerp(pillRect.top, cardRect.top, g)
            m.r = lerp(pillRect.right, cardRect.right, g)
            m.b = lerp(pillRect.bottom, cardRect.bottom, g)
            m.rad = lerp(pillRadius, cardRadius, g)
            view.invalidateOutline()
            if (bg != null) {
                // Opening: pill-black -> art tint over the first 55% (unchanged).
                // Closing: keep the art tint the whole way down and only reach
                // pill-black in the last ~12% of the shrink, when the card is
                // already pill-sized. Before, the card turned black while it was
                // still big -> the visible "black tint" while closing.
                val k = if (closing) (g / 0.12f).coerceIn(0f, 1f)
                        else (g / 0.55f).coerceIn(0f, 1f)
                setCardColors(bg, ColorUtils.blendARGB(Color.BLACK, currentExpandedTint, k))
            }
        }

        render(from)
        val a = ValueAnimator.ofFloat(from, to).apply {
            duration = durationMs
            interpolator = timing
            addUpdateListener { anim ->
                if (!view.isAttachedToWindow) { anim.cancel(); return@addUpdateListener }
                render(anim.animatedValue as Float)
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false
                override fun onAnimationCancel(animation: Animator) { cancelled = true }
                override fun onAnimationEnd(animation: Animator) {
                    if (cancelled) return
                    render(to)
                    onEnd()
                }
            })
        }
        cardAnimator = a
        a.start()
    }

    /** The card's resting shape: a plain rounded rect that follows its size. */
    private fun installRestOutline(view: View) {
        clipRounded(view, CARD_RADIUS_DP)
        view.invalidateOutline()
    }

    /** Content rises + fades in row by row while the card opens. */
    private fun staggerIn(root: View) {
        val g = root as? ViewGroup ?: return
        val lift = dpToPx(10f).toFloat()
        for (i in 0 until g.childCount) {
            val c = g.getChildAt(i)
            c.animate().cancel()
            c.alpha = 0f
            c.translationY = lift
            c.animate()
                .alpha(1f).translationY(0f)
                .setStartDelay(90L + i * 28L)
                .setDuration(240L)
                .setInterpolator(DecelerateInterpolator(1.6f))
                .start()
        }
    }

    private fun hideChildren(root: View) {
        val g = root as? ViewGroup ?: return
        val lift = dpToPx(10f).toFloat()
        for (i in 0 until g.childCount) {
            val c = g.getChildAt(i)
            c.animate().cancel()
            c.alpha = 0f
            c.translationY = lift
        }
    }

    private fun showChildrenNow(root: View) {
        val g = root as? ViewGroup ?: return
        for (i in 0 until g.childCount) {
            val c = g.getChildAt(i)
            c.animate().cancel()
            c.alpha = 1f
            c.translationY = 0f
        }
    }

    private fun pillRectInCard(cardW: Int, cardH: Int, pillOffsetX: Int): RectF {
        val pw = (if (pillW > 0) pillW else dpToPx(DEFAULT_WIDTH_DP)).toFloat()
        val ph = (if (pillH > 0) pillH else dpToPx(DEFAULT_HEIGHT_DP)).toFloat()
        val w = min(pw, cardW.toFloat())
        val h = min(ph, cardH.toFloat())
        val left = (cardW / 2f + pillOffsetX - w / 2f).coerceIn(0f, max(0f, cardW - w))
        return RectF(left, 0f, left + w, h)
    }

    private fun expand() {
        if (isExpanded || hiddenForForeground) return
        ensurePlayerListener()
        val outgoingPill = pillView
        val pillParams = outgoingPill?.layoutParams as? WindowManager.LayoutParams
        val pillOffsetX = pillParams?.x ?: 0

        addExpandedView()
        val ev = expandedView
        if (ev == null) {
            // Card failed to attach: leave the pill exactly as it was.
            Log.w(TAG, "expand aborted: card view not attached")
            return
        }
        isExpanded = true
        entranceDone = false
        thumbFailed.clear()
        outgoingPill?.let { tick(it) }

        // Nothing of the card may show before the morph has its first frame.
        hideChildren(ev)
        ev.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                ev.viewTreeObserver.removeOnPreDrawListener(this)
                if (expandedView !== ev || !isExpanded) return true
                val w = ev.width
                val h = ev.height
                entranceDone = true
                if (w <= 0 || h <= 0) {
                    installRestOutline(ev)
                    showChildrenNow(ev)
                    return true
                }
                animateOpenness(
                    view = ev,
                    pillRect = pillRectInCard(w, h, pillOffsetX),
                    cardRect = RectF(0f, 0f, w.toFloat(), h.toFloat()),
                    pillRadius = min(pillH.takeIf { it > 0 } ?: dpToPx(DEFAULT_HEIGHT_DP), h) / 2f,
                    cardRadius = dpToPx(CARD_RADIUS_DP).toFloat(),
                    from = 0f,
                    to = 1f,
                    durationMs = EXPAND_MS,
                    timing = expandInterpolator,
                ) { installRestOutline(ev) }
                staggerIn(ev)
                return true
            }
        })
        // Safety net: if the first frame never comes, never leave an invisible card.
        scope.launch {
            delay(800)
            if (!entranceDone && expandedView === ev) {
                entranceDone = true
                installRestOutline(ev)
                showChildrenNow(ev)
            }
        }

        if (outgoingPill != null) {
            pillView = null
            stopWaveBars()
            dyingViews.add(outgoingPill)
            // The card starts as an exact black copy of the pill, so the pill
            // can fade away underneath it without any visible seam.
            outgoingPill.animate()
                .alpha(0f)
                .setStartDelay(50L)
                .setDuration(110L)
                .withEndAction {
                    dyingViews.remove(outgoingPill)
                    removeWindowSafely(outgoingPill)
                }
                .start()
        }
        refreshFromPlayer()
        startSeekTicker()
        scheduleAutoCollapse()
    }

    private fun collapse() {
        if (!isExpanded) return
        isExpanded = false
        entranceDone = true
        seekTicker?.cancel()
        autoCollapseJob?.cancel()
        likeSyncJob?.cancel()
        isUserScrubbing = false
        val startOpenness = cardOpenness.coerceIn(0f, 1f)
        cardAnimator?.cancel()
        val outgoing = expandedView
        expandedView = null
        outgoing?.let { tick(it) }

        addPillView()
        val newPill = pillView
        val newParams = newPill?.layoutParams as? WindowManager.LayoutParams
        val pillOffsetX = newParams?.x ?: 0
        newPill?.let { p ->
            p.animate().cancel()
            p.alpha = 0f
            p.animate()
                .alpha(1f)
                .setStartDelay((COLLAPSE_MS * 0.6f).toLong())
                .setDuration((COLLAPSE_MS * 0.4f).toLong())
                .setInterpolator(DecelerateInterpolator())
                .start()
        }

        if (outgoing != null) {
            dyingViews.add(outgoing)
            val finish = {
                dyingViews.remove(outgoing)
                removeWindowSafely(outgoing)
            }
            val w = outgoing.width
            val h = outgoing.height
            if (w <= 0 || h <= 0) {
                finish()
            } else {
                // Content leaves first, then the card shrinks back into the pill.
                (outgoing as? ViewGroup)?.let { g ->
                    for (i in 0 until g.childCount) {
                        g.getChildAt(i).animate().cancel()
                        g.getChildAt(i).animate().alpha(0f).setStartDelay(0L).setDuration(110L).start()
                    }
                }
                animateOpenness(
                    view = outgoing,
                    pillRect = pillRectInCard(w, h, pillOffsetX),
                    cardRect = RectF(0f, 0f, w.toFloat(), h.toFloat()),
                    pillRadius = min(pillH.takeIf { it > 0 } ?: dpToPx(DEFAULT_HEIGHT_DP), h) / 2f,
                    cardRadius = dpToPx(CARD_RADIUS_DP).toFloat(),
                    from = startOpenness,
                    to = 0f,
                    durationMs = COLLAPSE_MS,
                    timing = collapseInterpolator,
                ) { finish() }
            }
        }
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
