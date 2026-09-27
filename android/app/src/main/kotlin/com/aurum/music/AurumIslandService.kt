package com.aurum.music

import android.animation.ValueAnimator
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.view.animation.OvershootInterpolator
import androidx.palette.graphics.Palette
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
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

/**
 * Dynamic-Island-style overlay: a small pill near the camera cutout while
 * something plays, tap-to-expand into a Spotify-full-player-style panel
 * (Aurum gold/dark instead of red, fully user-customizable position/size/
 * color from Settings -> Player), auto-collapsing back after a few
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
 *
 * Customization (position/size/color) is read once per view-add from
 * SharedPreferences (the same "FlutterSharedPreferences" store Dart's
 * Settings -> Player screen writes to, mirroring the island_enabled flag's
 * existing flutter.island_enabled convention) rather than pushed through a
 * MethodChannel — this service has no guarantee a Dart isolate is even
 * alive while it's running (the whole point of the overlay is surviving
 * app-minimized), so reading the persisted values directly is the only
 * path that works regardless of Dart's lifecycle.
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

        // Play/pause "icon-swap + scale-pop" timing — agreed alternative
        // to porting aurum_play_pause_icon.dart's full triangle<->bars
        // path-morph into native Kotlin/XML. Pops past 1.0 then eases
        // back, echoing that widget's own 1.0->1.25->1.0 scale beat
        // (toned down slightly here since this is a swap, not a morph —
        // 1.18 reads as a confident "tap landed" pop without looking
        // like an overshoot bug).
        private const val PLAY_POP_SCALE = 1.18f
        private const val PLAY_POP_MS = 260L

        // Expand/collapse fade+scale transition duration — used by both
        // animateIn() and animateOut() so the pill-shrinking-out and
        // card-growing-in halves of the swap always finish together.
        private const val TRANSITION_MS = 220L

        // SharedPreferences keys — all under the "flutter." prefix the
        // shared_preferences plugin already applies, matching
        // island_enabled's existing convention so Dart's Settings screen
        // and this service agree on the same store/keys without a channel
        // call in between.
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_X = "flutter.island_x_dp"                  // float, dp offset from horizontal center
        private const val KEY_Y = "flutter.island_y_dp"                  // float, dp offset from top
        private const val KEY_WIDTH = "flutter.island_width_dp"          // float, dp
        private const val KEY_HEIGHT = "flutter.island_height_dp"        // float, dp
        private const val KEY_COLOR = "flutter.island_accent_color"      // int ARGB, e.g. 0xFFB89640

        private const val DEFAULT_X_DP = 0f
        private const val DEFAULT_Y_DP = 8f
        private const val DEFAULT_WIDTH_DP = 101f
        private const val DEFAULT_HEIGHT_DP = 32f
        private const val DEFAULT_ACCENT = 0xFFB89640.toInt()

        @Volatile
        var isRunning: Boolean = false
            private set

        // Live handle to whichever instance is currently up, so
        // MainActivity's "updateIslandCustomization" MethodChannel call can
        // re-apply position/size/color to the *already-inflated* pill or
        // expanded view immediately — instead of the previous behavior
        // where a Settings change only took effect on the next pill<->
        // expanded swap (or never, if the overlay was stopped the whole
        // time the app was foregrounded, which it always is).
        @Volatile
        private var activeInstance: AurumIslandService? = null

        /** Re-reads SharedPreferences and re-applies position/size/color to
         *  whichever view (pill or expanded) is currently showing. No-op if
         *  no instance is running. Safe to call from the main thread only. */
        fun refreshCustomizationNow() {
            activeInstance?.reapplyCustomization()
        }

        /** Shows/hides the overlay without tearing the service (or its
         *  views) down. Used by MainActivity's onStart/onStop so the
         *  Island never draws over Aurum's own UI while the app itself is
         *  foregrounded, but reappears the instant the app is backgrounded
         *  — no re-inflate, no re-add-to-WindowManager, so none of the
         *  "flashes/expands awkwardly on return" glitches a full
         *  stopService()/startService() round-trip caused. No-op if no
         *  instance is running (MainActivity's onStart also runs before
         *  the overlay has ever started, which must stay harmless). */
        fun setHiddenForForeground(hidden: Boolean) {
            activeInstance?.applyForegroundHidden(hidden)
        }
    }

    private lateinit var windowManager: WindowManager
    private lateinit var prefs: SharedPreferences
    private var pillView: View? = null
    private var expandedView: View? = null
    private var isExpanded = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var autoCollapseJob: Job? = null
    private var lastArtworkUrl: String? = null
    private var lastPillBitmap: Bitmap? = null
    private var lastExpandedBitmap: Bitmap? = null
    private var seekTicker: Job? = null
    private var isUserScrubbing = false

    private var playerListener: Player.Listener? = null

    // True while Aurum's own Activity is in the foreground. The overlay
    // stays fully alive (views inflated, listeners registered, player
    // state syncing) the whole time — only View.GONE/VISIBLE toggles, so
    // there's nothing to re-inflate or re-add when the app is minimized
    // again, which is what made the old stop-service/start-service
    // approach look janky on return.
    private var hiddenForForeground = false

    // One looping ValueAnimator per bar, each with its own random
    // duration/height target so the three bars don't move in lockstep —
    // that's what actually reads as a "dancing waveform" instead of a
    // single pulsing block. Started on isPlaying=true, stopped (and bars
    // reset to the idle height) on isPlaying=false/pause/no song.
    private var waveAnimators: List<ValueAnimator>? = null
    private var waveBarsRunning = false

    // Pill thumbnail "breathing" pulse — a slow, gentle scale animator
    // (independent duration/interpolator from the wave bars, so the two
    // don't move in lockstep and end up looking like one mechanical
    // effect) that runs only while audio is actually playing, giving the
    // round artwork a subtle "alive" pulse the way the real iOS Dynamic
    // Island's artwork does. Confirmed scope: pill only — the expanded
    // sheet's artwork stays perfectly still/solid, matching the reference
    // screenshot's static Spotify-style card.
    private var thumbPulseAnimator: ValueAnimator? = null

    // Cached customization, re-read from SharedPreferences every time a
    // view is (re)built (addPillView/addExpandedView) so a change made in
    // Settings while the overlay is already up takes effect on the very
    // next pill<->expanded swap rather than needing a full restart.
    private data class IslandPrefs(
        val xDp: Float,
        val yDp: Float,
        val widthDp: Float,
        val heightDp: Float,
        val accentColor: Int,
    )

    private fun readPrefs(): IslandPrefs {
        // getFloat throws ClassCastException if the key was ever written
        // as a different type (e.g. a stale Double from an older build) —
        // guarded per-key so one bad legacy value can't crash the whole
        // overlay on every addView.
        fun safeFloat(key: String, default: Float): Float =
            try { prefs.getFloat(key, default) } catch (_: Throwable) { default }

        val xDp = safeFloat(KEY_X, DEFAULT_X_DP).coerceIn(-150f, 150f)
        val yDp = safeFloat(KEY_Y, DEFAULT_Y_DP).coerceIn(0f, 300f)
        // Width/height floors kept above the pill's natural content size
        // (24dp artwork + 16dp wave glyph + padding ≈ 78dp wide, ~36dp
        // tall including vertical padding) so a low slider value shrinks
        // the tap target/background only down to something that still
        // fully contains the pill's children — never clips the artwork
        // or waveform bars.
        val widthDp = safeFloat(KEY_WIDTH, DEFAULT_WIDTH_DP).coerceIn(90f, 360f)
        val heightDp = safeFloat(KEY_HEIGHT, DEFAULT_HEIGHT_DP).coerceIn(32f, 96f)
        val accent = try { prefs.getInt(KEY_COLOR, DEFAULT_ACCENT) } catch (_: Throwable) { DEFAULT_ACCENT }
        return IslandPrefs(xDp, yDp, widthDp, heightDp, accent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        isRunning = true
        activeInstance = this
        addPillView()
        registerPlayerListener()
        refreshFromPlayer()
        if (hiddenForForeground) pillView?.visibility = View.GONE
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
        if (activeInstance === this) activeInstance = null
        super.onDestroy()
    }

    /** Re-applies position/size/color to whichever view is currently up,
     *  without tearing the view down and re-adding it (which would cause a
     *  visible flicker on every slider tick while the user drags). Only
     *  the WindowManager params that actually change (gravity/x/y/size)
     *  require updateViewLayout; color is a plain view property change
     *  that redraws on its own. */
    private fun reapplyCustomization() {
        val prefsSnapshot = readPrefs()
        pillView?.let { view ->
            val params = view.layoutParams as? WindowManager.LayoutParams ?: return@let
            applyCustomization(view, params, prefsSnapshot, applySize = true)
            try { windowManager.updateViewLayout(view, params) } catch (_: Throwable) {}
        }
        expandedView?.let { view ->
            val params = view.layoutParams as? WindowManager.LayoutParams ?: return@let
            applyCustomization(view, params, prefsSnapshot, applySize = false)
            try { windowManager.updateViewLayout(view, params) } catch (_: Throwable) {}
        }
    }

    /** Toggles View.GONE/VISIBLE on whichever view (pill or expanded) is
     *  currently attached. Called only from the companion's
     *  setHiddenForForeground(); kept separate from the auto-collapse path
     *  so an app-foreground hide never fights the pill<->expanded swap. */
    private fun applyForegroundHidden(hidden: Boolean) {
        hiddenForForeground = hidden
        val visibility = if (hidden) View.GONE else View.VISIBLE
        if (hidden) {
            // Cancel any in-flight expand/collapse fade so a transient
            // outgoing pill/card mid-animation (animateOut hasn't fired
            // its withEndAction yet) doesn't linger half-faded, attached,
            // and untouched by the visibility toggle below.
            pillView?.animate()?.cancel()
            expandedView?.animate()?.cancel()
        }
        pillView?.visibility = visibility
        expandedView?.visibility = visibility
        if (hidden) {
            // Collapse first so returning to the app never leaves an
            // expanded card waiting to reappear mid-interaction — matches
            // tapping outside/auto-collapse's own behavior, just silent
            // (no view removal, so no flicker) since visibility is already
            // GONE by the time collapse() would otherwise re-add a pill.
            autoCollapseJob?.cancel()
            seekTicker?.cancel()
            isExpanded = false
            expandedView?.let {
                try { windowManager.removeView(it) } catch (_: Throwable) {}
            }
            expandedView = null
        } else {
            // Coming back from the foreground with nothing expanded —
            // make sure a pill exists to become visible (covers the case
            // where the service started fresh while the app was already
            // foregrounded, so addPillView() in onCreate() never ran
            // against a visible screen).
            if (!isExpanded && pillView == null) addPillView()
            // Re-read and re-apply position/size/color now, not just on
            // the next pill<->expanded swap — this is what makes slider
            // changes made in Settings while the app was open (when the
            // overlay was hidden and had nothing visible to preview them
            // on) actually show up the moment the app is minimized,
            // instead of the pill reappearing at its stale pre-edit
            // position/size until the next expand/collapse.
            reapplyCustomization()
            pillView?.visibility = View.VISIBLE
            refreshFromPlayer()
        }
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
        val hasSong = player != null && player.mediaItemCount > 0 && !metadata?.title?.toString().isNullOrEmpty()

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
            view.findViewById<TextView>(R.id.island_expanded_title)?.apply {
                text = title
                // marquee needs the view to report itself "selected" to
                // actually scroll — android:selected="true" in the XML
                // itself made AAPT fail resource linking on this CI's
                // toolchain (a strange but reproducible Android:selected
                // attribute-not-found error), so it's set here at runtime
                // instead, which achieves the identical scrolling effect.
                isSelected = true
            }
            view.findViewById<TextView>(R.id.island_expanded_artist)?.text = artist
            setPlayPauseState(view, isPlaying, animate = false)
            updateSeekbar(player)
            updateQueueThumbnails(player)
            updateLikeIcon(view)
            updateRouteIcon(view)
        }

        if (artworkUri != lastArtworkUrl) {
            lastArtworkUrl = artworkUri
            loadArtwork(artworkUri)
        }
    }

    private fun updateSeekbar(player: Player?) {
        if (player == null || isUserScrubbing) return
        val duration = player.duration.takeIf { it > 0 } ?: 1L
        val position = player.currentPosition.coerceIn(0L, duration)
        val seekbar = expandedView?.findViewById<SeekBar>(R.id.island_expanded_seekbar)
        seekbar?.max = 1000
        seekbar?.progress = ((position.toDouble() / duration.toDouble()) * 1000).toInt()
        expandedView?.findViewById<TextView>(R.id.island_expanded_position)?.text = formatMs(position)
        expandedView?.findViewById<TextView>(R.id.island_expanded_duration)?.text =
            if (player.duration > 0) formatMs(player.duration) else "0:00"
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

    // ---- Like ("+") button --------------------------------------------------

    /** Reflects [AurumAudioEngine.isCurrentSongLiked] state on the heart
     *  icon — reuses the exact assets/notification already relies on
     *  (ic_like_outline / ic_like_filled) so the Island's heart is
     *  pixel-identical to the one on the lock screen and notification. */
    private fun updateLikeIcon(view: View) {
        val engine = AurumMediaSessionService.sharedEngine ?: return
        val liked = engine.isCurrentSongLiked()
        view.findViewById<ImageView>(R.id.island_expanded_like)?.setImageResource(
            if (liked) R.drawable.ic_like_filled else R.drawable.ic_like_outline
        )
    }

    // ---- Audio route icon ---------------------------------------------------

    /** Speaker/Bluetooth glyph in the card's top-right corner, mirroring
     *  Spotify's own output-device icon. Cast state takes priority (an
     *  active Cast session is the most "another device" of all the
     *  routes), then a live AudioManager query for a connected Bluetooth
     *  A2DP/SCO/BLE sink, defaulting to the plain speaker glyph. This is a
     *  deliberately small self-contained check rather than reaching into
     *  AurumAudioEffects's private route detector, to avoid widening that
     *  file's API just for one icon here. */
    private fun updateRouteIcon(view: View) {
        val icon = view.findViewById<ImageView>(R.id.island_expanded_route_icon) ?: return
        val engine = AurumMediaSessionService.sharedEngine
        val isCasting = engine?.isCasting() == true
        if (isCasting) {
            icon.setImageResource(R.drawable.ic_island_speaker)
            icon.alpha = 1f
            return
        }
        val isBluetooth = try {
            val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            val devices = am?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            devices?.any {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
            } ?: false
        } catch (_: Throwable) {
            false
        }
        icon.setImageResource(if (isBluetooth) R.drawable.ic_island_bluetooth else R.drawable.ic_island_speaker)
        icon.alpha = 0.6f
    }

    // ---- Play/pause: icon-swap + scale-pop ----------------------------------

    /** Swaps the play/pause drawable and, when [animate] is true, runs a
     *  quick scale-pop on the icon — the agreed lightweight stand-in for
     *  porting the Dart player's full path-morph animation
     *  (AurumPlayPauseIcon / aurum_play_pause_icon.dart) into native
     *  Kotlin. [animate] is false on passive refreshes (e.g. metadata
     *  ticks, seek ticker) so the pop only plays on an actual user-driven
     *  transport action, not every 500ms refresh tick. */
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
                icon.animate()
                    .scaleX(1f).scaleY(1f)
                    .setDuration(PLAY_POP_MS / 2)
                    .start()
            }
            .start()
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
            startThumbPulse(root)
        } else {
            stopWaveBars()
        }
    }

    /** Slow, endless scale "breathing" pulse (1.0 -> 1.08 -> 1.0) on the
     *  pill's round artwork — deliberately much slower than the waveform
     *  bars' 260-420ms flicker so the two read as two separate, distinct
     *  motions rather than one blurred effect. Uses a reversing
     *  ValueAnimator (not a fixed loop) so it eases smoothly both ways
     *  instead of snapping back to 1.0 at the end of each cycle. */
    private fun startThumbPulse(pillRoot: View) {
        thumbPulseAnimator?.cancel()
        val thumb = pillRoot.findViewById<ImageView>(R.id.island_pill_artwork) ?: return
        thumb.scaleX = 1f
        thumb.scaleY = 1f
        val animator = ValueAnimator.ofFloat(1f, 1.08f).apply {
            duration = 900L
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = android.view.animation.AccelerateDecelerateInterpolator()
            addUpdateListener { anim ->
                val scale = anim.animatedValue as Float
                thumb.scaleX = scale
                thumb.scaleY = scale
            }
        }
        thumbPulseAnimator = animator
        animator.start()
    }

    private fun stopThumbPulse() {
        thumbPulseAnimator?.cancel()
        thumbPulseAnimator = null
        pillView?.findViewById<ImageView>(R.id.island_pill_artwork)?.apply {
            scaleX = 1f
            scaleY = 1f
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
        stopThumbPulse()
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

    // ---- Up-next queue thumbnails -------------------------------------------

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
                    val bmp = withContext(Dispatchers.IO) { downloadBitmap(uri) } ?: return@launch
                    val rounded = withContext(Dispatchers.Default) { roundBitmap(bmp, cornerRadiusPx = dpToPx(8f).toFloat()) }
                    imageView.setImageBitmap(rounded)
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
            // Pill artwork is a circle (matches the pill's own fully-round
            // capsule shape); the expanded card's artwork keeps square
            // proportions but with rounded corners matching the card's own
            // 32dp radius, so the art never reads as a hard square glued
            // inside a rounded card the way a plain ImageView did before.
            val pillBmp = withContext(Dispatchers.Default) { roundBitmap(bmp, cornerRadiusPx = null) }
            val expandedBmp = withContext(Dispatchers.Default) { roundBitmap(bmp, cornerRadiusPx = dpToPx(18f).toFloat()) }
            lastPillBitmap = pillBmp
            lastExpandedBitmap = expandedBmp
            pillView?.findViewById<ImageView>(R.id.island_pill_artwork)?.setImageBitmap(pillBmp)
            expandedView?.findViewById<ImageView>(R.id.island_expanded_artwork)?.setImageBitmap(expandedBmp)
            // Sampled from the original downloaded bmp (not the cropped/
            // rounded pill or card versions) so Palette sees the full,
            // un-cropped artwork for the most representative color read.
            tintExpandedBackground(bmp)
        }
    }

    /** Clips a bitmap to a circle (cornerRadiusPx == null) or a
     *  rounded-rect (cornerRadiusPx given), via BitmapShader — the
     *  reliable way to get real rounded corners on a bitmap set into a
     *  plain ImageView. clipToOutline()/setClipToOutline() on the
     *  ImageView itself is what island_pill_artwork relied on implicitly
     *  before (i.e. not at all), which is exactly why square album art
     *  showed up as a hard square glued into the round pill/card — this
     *  bakes the rounding into the bitmap itself so it holds regardless of
     *  view type or OEM quirks in a WindowManager overlay. */
    private fun roundBitmap(source: Bitmap, cornerRadiusPx: Float?): Bitmap {
        val size = min(source.width, source.height)
        val squared = Bitmap.createBitmap(
            source,
            (source.width - size) / 2,
            (source.height - size) / 2,
            size,
            size,
        )
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(output)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        val rect = android.graphics.RectF(0f, 0f, size.toFloat(), size.toFloat())
        if (cornerRadiusPx == null) {
            canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        } else {
            canvas.drawRoundRect(rect, cornerRadiusPx, cornerRadiusPx, paint)
        }
        paint.xfermode = android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(squared, 0f, 0f, paint)
        if (squared !== source) squared.recycle()
        return output
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

    // ---- Customization: position / size / color -----------------------------

    /** Applies the user's Settings -> Player customization to a freshly
     *  inflated pill/expanded root: horizontal gravity from [IslandPrefs.position],
     *  a uniform size multiplier via View.setScaleX/Y (simpler and
     *  cheaper than re-deriving every dimension in the layout), and the
     *  accent color tinted onto both the card background and every
     *  gold-colored control (seekbar, wordmark, waveform bars, shuffle
     *  icon) so "color" genuinely re-themes the whole card rather than
     *  just one element. */
    /** Applies the user's Settings -> Player customization to a freshly
     *  inflated pill/expanded root: X/Y offset from top-center via
     *  [WindowManager.LayoutParams], plus the accent color tinted onto
     *  both the card background and every gold-colored control (seekbar,
     *  wordmark, waveform bars, shuffle icon) so "color" genuinely
     *  re-themes the whole card rather than just one element.
     *
     *  [applySize] additionally pins the root to an explicit width/height
     *  from prefs — only ever passed true for the collapsed PILL. The
     *  expanded card's content (artwork, title, seekbar, transport
     *  controls, queue thumbnails) is far larger than the pill and was
     *  never meant to be squeezed into the same 90-360dp/32-96dp range;
     *  forcing it there would clip or overlap the card's own controls.
     *  The expanded card keeps its natural WRAP_CONTENT size regardless
     *  of the user's Island Width/Height sliders — only the collapsed
     *  pill's footprint is user-resizable. */
    private fun applyCustomization(
        root: View,
        params: WindowManager.LayoutParams,
        prefsSnapshot: IslandPrefs,
        applySize: Boolean,
    ) {
        // Anchored top-center. The X offset (left/right nudge) only ever
        // applies to the collapsed PILL — matching the customize screen's
        // "X is an offset from center" framing (negative = left of
        // center, positive = right). The EXPANDED card intentionally
        // ignores X and always opens perfectly centered/full-width, same
        // as Spotify's own full-player card — a pill nudged toward one
        // edge expanding into an off-center wide card would look broken.
        // Y (vertical drop from the top) still applies to both, since
        // that's just "how far down from the status bar" for either.
        params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        params.x = if (applySize) dpToPx(prefsSnapshot.xDp) else 0
        params.y = dpToPx(prefsSnapshot.yDp)

        if (applySize) {
            // Real width/height instead of a uniform scale transform — the
            // root is WRAP_CONTENT by default, so pin it to an explicit
            // pixel size here (pill only — see doc comment above). A
            // requestLayout is needed after changing params.width/height
            // on an already-attached view for the resize to take effect
            // immediately; reapplyCustomization's updateViewLayout call
            // covers that.
            params.width = dpToPx(prefsSnapshot.widthDp)
            params.height = dpToPx(prefsSnapshot.heightDp)
        }
        root.scaleX = 1f
        root.scaleY = 1f

        tintBackground(root.background, prefsSnapshot.accentColor)

        val accent = prefsSnapshot.accentColor
        (root.findViewById<SeekBar>(R.id.island_expanded_seekbar))?.let {
            it.progressTintList = android.content.res.ColorStateList.valueOf(accent)
            it.thumbTintList = android.content.res.ColorStateList.valueOf(accent)
        }
        root.findViewById<TextView>(R.id.island_expanded_wordmark)?.setTextColor(accent)
        listOf(
            root.findViewById<View>(R.id.island_wave_bar_1),
            root.findViewById<View>(R.id.island_wave_bar_2),
            root.findViewById<View>(R.id.island_wave_bar_3),
        ).forEach { bar ->
            (bar?.background as? GradientDrawable)?.mutate()?.let { d ->
                (d as GradientDrawable).setColor(accent)
            }
        }
        root.findViewById<ImageView>(R.id.island_expanded_shuffle)?.setColorFilter(accent)
    }

    /** Re-tints a GradientDrawable background (island_pill_bg /
     *  island_expanded_bg) in place via mutate()+setColor() rather than
     *  swapping in new drawable XML per color choice — keeps the
     *  customization data-driven (any ARGB int works) instead of needing
     *  a fixed palette of pre-baked drawables. Background stays near-
     *  black/dark regardless of accent (matches the original "always dark
     *  under the camera cutout" reasoning); only the accent-colored
     *  controls above pick up the user's chosen color. Left as a no-op if
     *  the drawable isn't a GradientDrawable for any reason — the card
     *  still renders with its default XML color rather than crashing. */
    private fun tintBackground(bg: android.graphics.drawable.Drawable?, @Suppress("UNUSED_PARAMETER") accent: Int) {
        val gd = bg?.mutate() as? GradientDrawable ?: return
        // Intentionally not recoloring the background fill itself (stays
        // dark per the original design), but this hook is where a future
        // "background follows accent" preference could plug in without
        // touching the rest of applyCustomization's callers.
        gd.setStroke(dpToPx(1f), Color.argb(0x33, Color.red(accent), Color.green(accent), Color.blue(accent)))
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
        val prefsSnapshot = readPrefs()

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        )
        params.y = 12
        applyCustomization(view, params, prefsSnapshot, applySize = true)

        view.setOnClickListener { expand() }

        try {
            windowManager.addView(view, params)
            pillView = view
            view.isHapticFeedbackEnabled = true
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
        val prefsSnapshot = readPrefs()

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        )
        params.y = 12
        applyCustomization(view, params, prefsSnapshot, applySize = false)

        wireExpandedControls(view)

        try {
            windowManager.addView(view, params)
            expandedView = view
            view.isHapticFeedbackEnabled = true
            // Apply the already-known tint immediately (no fade) so the
            // card opens in the right color for whatever song is already
            // playing, instead of flashing the XML default #13121C for one
            // frame and only correcting itself on the next song change.
            (view.background?.mutate() as? GradientDrawable)?.setColor(currentExpandedTint)
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

        view.findViewById<ImageView>(R.id.island_expanded_play_pause)?.let { btn ->
            btn.isHapticFeedbackEnabled = true
            btn.setOnClickListener {
                val e = engine() ?: return@setOnClickListener
                val nowPlaying = !e.player.isPlaying
                if (nowPlaying) e.play() else e.pause()
                setPlayPauseState(view, nowPlaying, animate = true)
                tick(btn)
                scheduleAutoCollapse()
            }
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
        // "+"/heart button — reuses the exact same toggle path the
        // notification/lock-screen like button already drives
        // (engine.triggerLikeToggle() -> Dart's onLikeToggleRequested ->
        // FavoritesProvider's Hive-backed toggleFavorite), so a like made
        // from the Island shows up as liked everywhere else in the app
        // (and vice versa) without the Island needing its own persistence.
        view.findViewById<ImageView>(R.id.island_expanded_like)?.let { likeBtn ->
            likeBtn.isHapticFeedbackEnabled = true
            likeBtn.setOnClickListener {
                engine()?.triggerLikeToggle()
                // Optimistic flip — the real state round-trips back through
                // Dart asynchronously, but reflecting the tap immediately
                // here (rather than waiting) is what makes it feel responsive
                // the way Spotify's own heart-tap does.
                updateLikeIcon(view)
                tick(likeBtn)
                scheduleAutoCollapse()
            }
        }

        // Draggable seekbar — mirrors tapping/dragging Spotify's own
        // progress bar. isUserScrubbing suppresses updateSeekbar()'s
        // periodic overwrites while a drag is in progress so the ticker
        // doesn't fight the user's thumb.
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
                    view.findViewById<TextView>(R.id.island_expanded_position)?.text = formatMs(targetMs)
                }
                override fun onStopTrackingTouch(seekBar: SeekBar) {
                    val player = engine()?.player
                    val duration = player?.duration?.takeIf { it > 0 }
                    if (player != null && duration != null) {
                        val targetMs = (duration * (seekBar.progress / 1000.0)).toLong()
                        player.seekTo(targetMs)
                    }
                    isUserScrubbing = false
                    scheduleAutoCollapse()
                }
            }
        )

        // Tapping anywhere else on the card collapses it immediately,
        // same as tapping outside per the confirmed spec.
        view.setOnClickListener { collapse() }
    }

    // ---- Expand / collapse --------------------------------------------------

    /** Fades+scales [view] in from [fromScale] to 1.0/alpha 1, anchored at
     *  its own center (pivot defaults to center for a WRAP_CONTENT root,
     *  which is what both island_pill and island_expanded are) — this is
     *  what makes the pill->card swap read as one continuous "grow" motion
     *  instead of the old instant swap-in-place. A very mild
     *  OvershootInterpolator (tension 1.2f, barely past 1.0 scale) is used
     *  instead of a flat decelerate — this is what gives the real Dynamic
     *  Island / Spotify expand its small "springy settle" instead of
     *  gliding to a dead stop. Kept subtle deliberately: a strong overshoot
     *  reads as bouncy/toy-like, not premium. */
    private fun animateIn(view: View, fromScale: Float) {
        view.alpha = 0f
        view.scaleX = fromScale
        view.scaleY = fromScale
        view.animate()
            .alpha(1f)
            .scaleX(1f).scaleY(1f)
            .setDuration(TRANSITION_MS)
            .setInterpolator(OvershootInterpolator(1.2f))
            .start()
    }

    /** Fades+scales [view] out down to [toScale], then runs [onEnd] (used
     *  to actually removeView() the old pill/card only once it's no longer
     *  visible — removing it immediately, as the old code did, is what
     *  made the swap look like an instant cut rather than a transition). */
    private fun animateOut(view: View, toScale: Float, onEnd: () -> Unit) {
        view.animate()
            .alpha(0f)
            .scaleX(toScale).scaleY(toScale)
            .setDuration(TRANSITION_MS)
            .setInterpolator(android.view.animation.AccelerateInterpolator())
            .withEndAction(onEnd)
            .start()
    }

    /** Animates a view's rounded-rect background corner radius from
     *  [fromRadiusPx] to [toRadiusPx] over the same [TRANSITION_MS] window
     *  as animateIn/animateOut, so the pill's 28dp capsule and the card's
     *  32dp corners read as one continuous shape stretching open/closed —
     *  the actual signature trait of a real Dynamic Island morph, on top
     *  of (not replacing) the existing fade+scale. Silently no-ops if the
     *  view's background isn't a GradientDrawable (defensive: island_pill_bg
     *  and island_expanded_bg both are, per their own <shape> XML, but this
     *  must never crash the overlay if that ever changes) — the fade+scale
     *  motion alone still carries the transition in that case, so nothing
     *  looks broken, just slightly less seamless. */
    private fun animateCornerRadius(view: View, fromRadiusPx: Float, toRadiusPx: Float) {
        val bg = view.background?.mutate() as? GradientDrawable ?: return
        bg.cornerRadius = fromRadiusPx
        // Stopped early if the view is detached from its window mid-morph
        // (removeView() already happened) so it never keeps ticking on a
        // view nothing can see anymore — same spirit as the existing
        // pillView?.animate()?.cancel() guard in applyForegroundHidden().
        ValueAnimator.ofFloat(fromRadiusPx, toRadiusPx).apply {
            duration = TRANSITION_MS
            interpolator = android.view.animation.DecelerateInterpolator()
            addUpdateListener { anim ->
                if (!view.isAttachedToWindow) { cancel(); return@addUpdateListener }
                bg.cornerRadius = anim.animatedValue as Float
            }
            start()
        }
    }

    /** Short, light tap tick — matches the subtlety of the real Dynamic
     *  Island / Spotify's own haptic feedback on expand/collapse/like/
     *  play-pause. Uses the view's own performHapticFeedback (no extra
     *  permission needed, respects the user's system haptics setting
     *  automatically) rather than a raw Vibrator call. CONTEXT_CLICK reads
     *  as a light "tick" rather than the heavier default click buzz. */
    private fun tick(view: View) {
        view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    }

    /** Extracts the artwork's dominant/vibrant color via Palette and
     *  cross-fades the expanded card's background to a darkened version of
     *  it — this is the actual "art-adaptive background" that makes
     *  Spotify's own full-player card read as premium (a red album cover
     *  giving a deep red card, a blue cover giving a deep blue card)
     *  instead of one fixed color for every song. Runs on
     *  Dispatchers.Default since Palette.from(bmp).generate() does real
     *  pixel-sampling work, same reasoning as the existing roundBitmap()
     *  offload. Swatch preference order (vibrant -> muted -> dominant ->
     *  null) mirrors Palette's own documented fallback chain for "most
     *  visually interesting representative color." Darkened via
     *  ColorUtils.blendARGB toward the card's own #13121C base (kept at
     *  78% tint / 22% base) rather than used raw — a straight vibrant
     *  swatch is usually too bright/saturated to sit behind white title
     *  text at full card size; blending toward near-black is what gives
     *  Spotify's own tinted cards their "deep," not "neon," look while
     *  keeping the existing white/translucent text readable with no
     *  further changes needed. Silently no-ops (keeps the current/default
     *  background) if the view's background isn't a GradientDrawable or if
     *  Palette finds no usable swatch — this must never crash the overlay
     *  or leave the card looking broken; falling back to the shipped
     *  #13121C default is always a safe, finished-looking result. */
    private var currentExpandedTint: Int = Color.parseColor("#13121C")

    /** Extracts the artwork's dominant/vibrant color via Palette and
     *  cross-fades the expanded card's background to a darkened version of
     *  it — this is the actual "art-adaptive background" that makes
     *  Spotify's own full-player card read as premium (a red album cover
     *  giving a deep red card, a blue cover giving a deep blue card)
     *  instead of one fixed color for every song. Runs on
     *  Dispatchers.Default since Palette.from(bmp).generate() does real
     *  pixel-sampling work, same reasoning as the existing roundBitmap()
     *  offload. Swatch preference order (vibrant -> muted -> dominant ->
     *  null) mirrors Palette's own documented fallback chain for "most
     *  visually interesting representative color." Darkened via
     *  ColorUtils.blendARGB toward the card's own #13121C base (kept at
     *  78% tint / 22% base) rather than used raw — a straight vibrant
     *  swatch is usually too bright/saturated to sit behind white title
     *  text at full card size; blending toward near-black is what gives
     *  Spotify's own tinted cards their "deep," not "neon," look while
     *  keeping the existing white/translucent text readable with no
     *  further changes needed. Always computes and stores the tint (even
     *  while collapsed, when expandedView is null) so a card expanded
     *  later opens directly in the right color instead of the stale
     *  previous song's tint for one frame — only the actual cross-fade
     *  animation is skipped when there's no live view to animate.
     *  Silently no-ops the whole card-coloring step (keeps whatever tint
     *  is already stored) if Palette finds no usable swatch — this must
     *  never crash the overlay or leave the card looking broken; falling
     *  back to the shipped #13121C default on first run is always a safe,
     *  finished-looking result. */
    private suspend fun tintExpandedBackground(bitmap: Bitmap) {
        val swatchColor = withContext(Dispatchers.Default) {
            val palette = Palette.from(bitmap).generate()
            (palette.vibrantSwatch ?: palette.mutedSwatch ?: palette.dominantSwatch)?.rgb
        } ?: return
        val cardBase = Color.parseColor("#13121C")
        val tinted = androidx.core.graphics.ColorUtils.blendARGB(cardBase, swatchColor, 0.78f)
        val fromColor = currentExpandedTint
        currentExpandedTint = tinted
        val view = expandedView ?: return
        val bg = view.background?.mutate() as? GradientDrawable ?: return
        ValueAnimator.ofArgb(fromColor, tinted).apply {
            duration = TRANSITION_MS
            interpolator = android.view.animation.DecelerateInterpolator()
            addUpdateListener { anim ->
                if (!view.isAttachedToWindow) { cancel(); return@addUpdateListener }
                bg.setColor(anim.animatedValue as Int)
            }
            start()
        }
    }

    private fun expand() {
        if (isExpanded || hiddenForForeground) return
        isExpanded = true
        val outgoingPill = pillView
        outgoingPill?.let { tick(it) }
        addExpandedView()
        expandedView?.let { ev ->
            // If the pill sits off-center (user-set X offset in Settings),
            // start the card translated to that same X and animate it back
            // to 0 alongside the existing fade+scale — otherwise the card
            // (which always opens perfectly centered, per applyCustomization's
            // own reasoning) would visibly "pop" straight to center from an
            // off-center pill instead of growing out of the pill's actual
            // on-screen spot. No-op (translationX stays 0) for the default
            // centered pill, so the common case is unaffected.
            val pillOffsetPx = dpToPx(readPrefs().xDp).toFloat()
            if (pillOffsetPx != 0f) {
                ev.translationX = pillOffsetPx
                ev.animate().translationX(0f)
                    .setDuration(TRANSITION_MS)
                    .setInterpolator(OvershootInterpolator(1.2f))
                    .start()
            }
            animateIn(ev, fromScale = 0.86f)
            animateCornerRadius(ev, fromRadiusPx = dpToPx(28f).toFloat(), toRadiusPx = dpToPx(32f).toFloat())
        }
        if (outgoingPill != null) {
            // Detach the pill from the isExpanded-driven lifecycle
            // immediately (so a rapid re-tap can't double-remove it) but
            // only actually tear it out of WindowManager once its fade-out
            // finishes, so the pill visibly shrinks/fades away under the
            // growing card instead of just vanishing.
            pillView = null
            stopWaveBars()
            animateOut(outgoingPill, toScale = 0.9f) {
                try { windowManager.removeView(outgoingPill) } catch (_: Throwable) {}
            }
        }
        refreshFromPlayer()
        startSeekTicker()
        scheduleAutoCollapse()
    }

    private fun collapse() {
        if (!isExpanded) return
        isExpanded = false
        seekTicker?.cancel()
        autoCollapseJob?.cancel()
        val outgoingExpanded = expandedView
        outgoingExpanded?.let { tick(it) }
        expandedView = null
        addPillView()
        pillView?.let {
            animateIn(it, fromScale = 1.12f)
            animateCornerRadius(it, fromRadiusPx = dpToPx(32f).toFloat(), toRadiusPx = dpToPx(28f).toFloat())
        }
        if (outgoingExpanded != null) {
            // Symmetric with expand()'s off-center start: shrink the card
            // back toward the pill's actual X position (if non-center)
            // instead of shrinking in place and leaving the new pill to
            // just appear at its offset spot disconnected from the card.
            val pillOffsetPx = dpToPx(readPrefs().xDp).toFloat()
            if (pillOffsetPx != 0f) {
                outgoingExpanded.animate().translationX(pillOffsetPx)
                    .setDuration(TRANSITION_MS)
                    .setInterpolator(android.view.animation.AccelerateInterpolator())
                    .start()
            }
            animateOut(outgoingExpanded, toScale = 1.06f) {
                try { windowManager.removeView(outgoingExpanded) } catch (_: Throwable) {}
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
