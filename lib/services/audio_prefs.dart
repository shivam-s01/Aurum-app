import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Immutable bundle of lyrics text formatting settings.
class LyricsStyle {
  final String position;   // 'Left' | 'Centre'
  final double textSize;   // sp
  final double lineSpacing; // height multiplier

  const LyricsStyle({
    this.position = 'Centre',
    this.textSize = 16.0,
    this.lineSpacing = 2.0,
  });

  LyricsStyle copyWith({String? position, double? textSize, double? lineSpacing}) =>
      LyricsStyle(
        position: position ?? this.position,
        textSize: textSize ?? this.textSize,
        lineSpacing: lineSpacing ?? this.lineSpacing,
      );
}

/// Lightweight static bridge so service-layer code (ApiService,
/// AurumAudioHandler) can read live Player & Audio settings without a
/// BuildContext.
///
/// The Settings → Player & Audio screen calls the setters below directly
/// (in addition to its own SharedPreferences writes) so changes take effect
/// immediately — no app restart needed. [load] restores everything from
/// disk once at startup.
class AudioPrefs {
  AudioPrefs._();

  /// 'Auto' | 'Low' | 'Medium' | 'High' — matches the Stream Quality
  /// dropdown values in Settings → Player & Audio.
  static String streamQuality = 'Auto';

  /// Forces the lowest available stream quality regardless of
  /// [streamQuality] — used to save mobile data. Overrides streamQuality.
  static bool dataSaver = false;

  /// Approximate kbps of the most recently resolved stream URL (e.g. 320,
  /// 160, 96, 48, 12 for Saavn tiers; null when unknown, such as for
  /// YouTube-sourced streams where no discrete tier is reported). Not
  /// persisted — reset per resolution, purely so the native side (Premium
  /// Sound's low-bitrate compensation curve) can know how compressed the
  /// current source is without needing a full metadata pipeline.
  static int? lastResolvedKbps;

  /// If true (default), playback pauses when a phone call interrupts audio.
  /// If false, Aurum ignores call interruptions and keeps playing wherever
  /// the OS allows the app to retain audio focus.
  static bool pauseOnCall = true;

  /// If true, playback volume is ducked/paused for short transient sounds
  /// (e.g. a notification chime). Default false — notifications should NOT
  /// lower or stop song playback.
  static bool duckOnNotifications = false;

  /// If true (default), show previous track button in notification.
  static bool notifShowPrev = true;

  /// If true, use compact notification style (fewer buttons).
  static bool notifCompact = false;

  /// If true (default), show the media notification while playing.
  /// If false, the notification is suppressed (processingState set to idle).
  static bool showMediaNotif = true;

  /// If true (default), include song artwork bitmap in the notification.
  /// If false, artUri is omitted — smaller notification, no album art shown.
  static bool showArtworkNotif = true;

  /// If true (default), tracks play back-to-back with no gap.
  /// If false, a 600ms silence gap is inserted between tracks.
  static bool gapless = true;

  static bool incognito = false;

  /// If true (default), screen-to-screen navigation uses the slide+fade
  /// AurumPageRoute transition. If false, navigation cuts instantly.
  /// Set from Settings → Appearance → "Back Animations".
  static bool backAnimations = true;

  /// 'Square' | 'Rounded' | 'Circle' — drives the corner radius of the
  /// main player artwork. Set from Settings → Appearance. Wrapped in a
  /// ValueNotifier (not a plain static) so the full player screen can
  /// rebuild live when the setting changes, even if it's already open.
  static final ValueNotifier<String> artworkShapeNotifier =
      ValueNotifier<String>('Rounded');
  static String get artworkShape => artworkShapeNotifier.value;

  /// Lyrics text formatting — position ('Left'/'Centre'), size (sp), and
  /// line spacing (height multiplier). Bundled in one ValueNotifier so the
  /// lyrics page rebuilds live when any of these change in Settings.
  static final ValueNotifier<LyricsStyle> lyricsStyleNotifier =
      ValueNotifier<LyricsStyle>(const LyricsStyle());

  /// Spotify-style single active lyric line shown inline on the full
  /// player between the song title/artist and the seek bar. Set from
  /// Settings → Appearance → Lyrics.
  static final ValueNotifier<bool> showLyricsOnPlayerNotifier =
      ValueNotifier<bool>(true);

  /// Controls when the Chromecast icon shows on the full player:
  ///  - 'auto'   (default) — icon only appears once a Cast device is
  ///    actually detected on the network, same as Spotify/YT Music.
  ///  - 'always' — icon always shows (even with no device detected yet),
  ///    for users who'd rather see it's there and know casting exists,
  ///    at the cost of a tap sometimes finding "no devices" if none are
  ///    on the network at that moment.
  ///  - 'hidden' — icon never shows, for users who don't use casting and
  ///    want one less icon in the top bar.
  /// Set from Settings → Player & Audio → "Show Chromecast icon".
  static final ValueNotifier<String> castIconVisibilityNotifier =
      ValueNotifier<String>('auto');

  /// If true, swiping left/right on the full player artwork
  /// skips to the next/previous track. Set from Settings → Player & Audio.
  static final ValueNotifier<bool> swipeToChangeNotifier =
      ValueNotifier<bool>(true);

  /// If true, shaking the phone skips to the next track. Set from
  /// Settings → Player & Audio → "Shake to Skip Song". Default false —
  /// opt-in, since accidental shakes (walking, in a bag) shouldn't skip
  /// tracks unless the user explicitly enables it.
  static final ValueNotifier<bool> shakeToSkipNotifier =
      ValueNotifier<bool>(false);

  /// If true, swiping the app away from Recents stops playback + the
  /// foreground service. If false, playback keeps running in the
  /// background after the app is swiped away. Set from
  /// Settings → Player & Audio → "Stop on Swipe from Recents". Mirrored to
  /// native (Kotlin) via a MethodChannel call in [pushStopOnSwipeToNative]
  /// so AurumMediaSessionService.onTaskRemoved can honor it — this is a
  /// native Android lifecycle callback with no Dart involvement at the
  /// moment it fires, so the flag has to already be sitting on the native
  /// side before the swipe happens, not read reactively at swipe-time.
  static final ValueNotifier<bool> stopOnSwipeNotifier =
      ValueNotifier<bool>(false);

  /// 0–100 — how far you need to drag before a swipe registers as a skip.
  /// Higher = more sensitive (shorter swipe needed). Set from
  /// Settings → Appearance → "Swipe Sensitivity".
  static double swipeSensitivity = 50.0;

  /// 'Gradient' | 'Blur' (default) | 'Solid' — overall background render
  /// mode for the full player. 'Blur' = gradient + blurred artwork (full
  /// experience). 'Gradient' = palette gradient only, no artwork blur.
  /// 'Solid' = a single flat palette color, no gradient/glow — cheapest to
  /// render. Set from Settings → Appearance.
  static final ValueNotifier<String> playerBgStyleNotifier =
      ValueNotifier<String>('Blur');

  /// If true (default), the full player background uses colors extracted
  /// from the song artwork (palette generator). If false, falls back to a
  /// static gold-tinted palette. Set from Settings → Appearance.
  static final ValueNotifier<bool> dynamicPlayerColorNotifier =
      ValueNotifier<bool>(true);

  /// If true (default), the full player background shows a blurred,
  /// low-opacity copy of the song artwork behind the gradient. If false,
  /// just the gradient + ambient glows (cheaper to render, more minimal
  /// look). Set from Settings → Appearance.
  static final ValueNotifier<bool> showBlurredBgNotifier =
      ValueNotifier<bool>(true);

  /// 0–24 (default 24) — blur sigma for the bottom nav bar's frosted-glass
  /// BackdropFilter. This bar is on screen on every tab, so its blur runs
  /// on every single frame it's visible — a real, continuous GPU/battery
  /// cost, most noticeable as device heat during long listening sessions
  /// on weaker GPUs. Set from Settings → Appearance → "Nav Bar Blur". 0
  /// disables the BackdropFilter entirely (falls back to a flat tinted
  /// bar, matching FullPlayerScreen's own _routeAnimating flat-color
  /// fallback pattern) — the cheapest possible option for users who'd
  /// rather trade the frosted look for cooler/longer battery life.
  static final ValueNotifier<double> navBarBlurSigmaNotifier =
      ValueNotifier<double>(24.0);

  /// 0–14 (default 14) — blur sigma for the mini player's frosted-glass
  /// BackdropFilter. Same reasoning/tradeoff as [navBarBlurSigmaNotifier]
  /// above; kept as a separate setting since the mini player and nav bar
  /// are independent widgets a user may want tuned differently (e.g. mini
  /// player blur is already suppressed during route transitions — see
  /// mini_player.dart's _routeAnimating — so its steady-state cost is
  /// lower to begin with). Set from Settings → Appearance → "Mini Player
  /// Blur". 0 disables the BackdropFilter entirely.
  static final ValueNotifier<double> miniPlayerBlurSigmaNotifier =
      ValueNotifier<double>(14.0);

  // ── Battery Saver Mode ───────────────────────────────────────────────
  // A separate feature from the individual animation/background toggles
  // above — those stay exactly as the user set them. Battery Saver Mode
  // is a live, automatic OVERRIDE on top: when active, every consumer of
  // AurumMotion.enabled / the background-effect notifiers sees motion
  // and heavy rendering suppressed, without touching (or forgetting) the
  // user's actual saved preferences underneath. The moment battery
  // recovers above the threshold, everything reads through to exactly
  // what it was before — nothing was overwritten, only masked.
  //
  // Toggle here has no "on/off" wording — the feature always watches
  // battery level once enabled ("Automatic"); there's no manual trigger,
  // only enabled/disabled and a chosen threshold.

  /// If true, Battery Saver Mode automatically activates once the device
  /// battery drops to/below [batterySaverThresholdNotifier]. If false,
  /// the feature is fully off — [batterySaverActiveNotifier] never
  /// becomes true regardless of battery level. Default true so the
  /// protection is on out of the box, matching how most OS-level battery
  /// savers ship enabled-by-default at a sensible threshold.
  static final ValueNotifier<bool> batterySaverEnabledNotifier =
      ValueNotifier<bool>(true);

  /// 15 or 20 — battery percentage at/below which Battery Saver Mode
  /// engages. Default 20. Set from Settings → Player & Audio → "Battery
  /// Saver Mode".
  static final ValueNotifier<int> batterySaverThresholdNotifier =
      ValueNotifier<int>(20);

  /// Live computed state — true while Battery Saver Mode is enabled AND
  /// the last-reported battery level is at/below the threshold. Written
  /// only by BatterySaverController (lib/services/battery_saver_controller.dart),
  /// which owns the native battery-level stream subscription; never set
  /// directly from UI code. UI/animation code should treat this as
  /// read-only.
  static final ValueNotifier<bool> batterySaverActiveNotifier =
      ValueNotifier<bool>(false);

  /// Most recently reported battery percentage (0-100), or null before
  /// the first native battery event has arrived. Purely informational —
  /// drives the settings subtitle ("Active — battery at 14%"), not used
  /// for the activation decision itself (that's batterySaverActiveNotifier).
  static final ValueNotifier<int?> batteryLevelNotifier =
      ValueNotifier<int?>(null);

  /// If true, play counts / time-listened are not tracked. Set from
  /// Settings → Privacy.
  static bool hideListenStats = false;

  /// Mirrors PremiumProvider.isPremium for service-layer code (ApiService)
  /// that has no BuildContext. Set by PremiumProvider whenever its value
  /// changes. Default false — never self-grant.
  static bool isPremium = false;

  /// Mirrors AuthProvider.isSignedIn for service-layer code (PlayerProvider)
  /// that has no BuildContext. Set by AuthProvider whenever its value
  /// changes. Backs the many features gated on "has a Google account" only
  /// (Unlimited Skips, Like Songs, Playlists, Follow Artist, Cloud Sync,
  /// Themes/Fonts/Player Styles) as distinct from the single feature still
  /// gated on payment (High Bitrate — see isPremium above). Default false
  /// — never self-grant.
  static bool isSignedIn = false;

  static const _kStreamQuality = 'stream_quality';
  static const _kDataSaver     = 'data_saver';
  static const _kPauseOnCall   = 'pause_on_call';
  static const _kDuckNotif     = 'duck_on_notifications';
  static const _kIncognito     = 'incognito_mode';
  static const _kBackAnim      = 'back_animations';
  static const _kArtworkShape  = 'artwork_shape';
  static const _kLyricsPos     = 'lyrics_text_position';
  static const _kLyricsSize    = 'lyrics_text_size';
  static const _kLyricsSpacing = 'lyrics_line_spacing';
  static const _kShowLyricsOnPlayer = 'show_lyrics_on_player';
  static const _kSwipeChange   = 'swipe_to_change';
  static const _kShakeToSkip   = 'shake_to_skip';
  static const _kStopOnSwipe   = 'stop_on_swipe';
  static const _kSwipeSens     = 'swipe_sensitivity';
  static const _kDynamicColor  = 'dynamic_player_color';
  static const _kShowBlurBg    = 'show_blurred_bg';
  static const _kNavBarBlur    = 'nav_bar_blur_sigma';
  static const _kMiniPlayerBlur = 'mini_player_blur_sigma';
  static const _kPlayerBgStyle = 'player_bg_style';
  static const _kMiniPlayerBg  = 'mini_player_bg_style';
  static const _kBgGradAnim    = 'bg_gradient_animation';
  static const _kEnableAnim    = 'enable_animations';
  static const _kHideStats     = 'hide_listen_stats';
  static const _kNotifShowPrev = 'notif_show_prev';
  static const _kNotifStyle    = 'notif_style';
  static const _kShowMediaNotif   = 'show_media_notif';
  static const _kShowArtworkNotif = 'show_artwork_notif';
  static const _kGapless          = 'gapless';
  static const _kCastIconVisibility = 'cast_icon_visibility';
  static const _kBatterySaverEnabled   = 'battery_saver_enabled';
  static const _kBatterySaverThreshold = 'battery_saver_threshold';

  /// Restore all values from disk. Call once at startup (from the audio
  /// handler's _init()).
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    streamQuality       = p.getString(_kStreamQuality) ?? streamQuality;
    dataSaver           = p.getBool(_kDataSaver) ?? dataSaver;
    pauseOnCall         = p.getBool(_kPauseOnCall) ?? pauseOnCall;
    duckOnNotifications = p.getBool(_kDuckNotif) ?? duckOnNotifications;
    incognito           = p.getBool(_kIncognito) ?? incognito;
    backAnimations      = p.getBool(_kBackAnim) ?? backAnimations;
    artworkShapeNotifier.value = p.getString(_kArtworkShape) ?? artworkShape;
    lyricsStyleNotifier.value = LyricsStyle(
      position:    p.getString(_kLyricsPos) ?? lyricsStyleNotifier.value.position,
      textSize:    p.getDouble(_kLyricsSize) ?? lyricsStyleNotifier.value.textSize,
      lineSpacing: p.getDouble(_kLyricsSpacing) ?? lyricsStyleNotifier.value.lineSpacing,
    );
    swipeToChangeNotifier.value = p.getBool(_kSwipeChange) ?? swipeToChangeNotifier.value;
    showLyricsOnPlayerNotifier.value =
        p.getBool(_kShowLyricsOnPlayer) ?? showLyricsOnPlayerNotifier.value;
    shakeToSkipNotifier.value = p.getBool(_kShakeToSkip) ?? shakeToSkipNotifier.value;
    stopOnSwipeNotifier.value = p.getBool(_kStopOnSwipe) ?? stopOnSwipeNotifier.value;
    // PERF FIX (cold-start): this was `await`-ed here, inside a call chain
    // that main.dart itself awaits before runApp() — meaning a real
    // MethodChannel round-trip was sitting in the pre-first-frame blocking
    // path, the same class of issue fixed in DownloadProvider.init() (see
    // that file's NOTE). The native side only needs this value to have
    // arrived before Android could plausibly fire onTaskRemoved, which
    // requires the user to have already opened the app and put it in
    // Recents — there's no correctness reason this needs to finish before
    // the first frame paints. Fire-and-forget instead; still try-caught
    // inside pushStopOnSwipeToNative itself.
    unawaited(pushStopOnSwipeToNative(stopOnSwipeNotifier.value));
    swipeSensitivity = p.getDouble(_kSwipeSens) ?? swipeSensitivity;
    dynamicPlayerColorNotifier.value = p.getBool(_kDynamicColor) ?? dynamicPlayerColorNotifier.value;
    showBlurredBgNotifier.value = p.getBool(_kShowBlurBg) ?? showBlurredBgNotifier.value;
    navBarBlurSigmaNotifier.value = p.getDouble(_kNavBarBlur) ?? navBarBlurSigmaNotifier.value;
    miniPlayerBlurSigmaNotifier.value =
        p.getDouble(_kMiniPlayerBlur) ?? miniPlayerBlurSigmaNotifier.value;
    playerBgStyleNotifier.value = p.getString(_kPlayerBgStyle) ?? playerBgStyleNotifier.value;
    miniPlayerBgStyleNotifier.value = p.getString(_kMiniPlayerBg) ?? miniPlayerBgStyleNotifier.value;
    bgGradientAnimationNotifier.value = p.getBool(_kBgGradAnim) ?? bgGradientAnimationNotifier.value;
    enableAnimationsNotifier.value = p.getBool(_kEnableAnim) ?? enableAnimationsNotifier.value;
    batterySaverEnabledNotifier.value =
        p.getBool(_kBatterySaverEnabled) ?? batterySaverEnabledNotifier.value;
    batterySaverThresholdNotifier.value =
        p.getInt(_kBatterySaverThreshold) ?? batterySaverThresholdNotifier.value;
    hideListenStats     = p.getBool(_kHideStats) ?? hideListenStats;
    notifShowPrev       = p.getBool(_kNotifShowPrev) ?? notifShowPrev;
    notifCompact        = (p.getString(_kNotifStyle) ?? 'Expanded') == 'Compact';
    showMediaNotif      = p.getBool(_kShowMediaNotif) ?? showMediaNotif;
    showArtworkNotif    = p.getBool(_kShowArtworkNotif) ?? showArtworkNotif;
    gapless             = p.getBool(_kGapless) ?? gapless;
    castIconVisibilityNotifier.value =
        p.getString(_kCastIconVisibility) ?? castIconVisibilityNotifier.value;
  }

  static Future<void> setStreamQuality(String v) async {
    streamQuality = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kStreamQuality, v);
  }

  static Future<void> setDataSaver(bool v) async {
    dataSaver = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDataSaver, v);
  }

  static Future<void> setPauseOnCall(bool v) async {
    pauseOnCall = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPauseOnCall, v);
  }

  static Future<void> setDuckOnNotifications(bool v) async {
    duckOnNotifications = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDuckNotif, v);
  }

  static Future<void> setIncognito(bool v) async {
    incognito = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kIncognito, v);
  }

  static Future<void> setBackAnimations(bool v) async {
    backAnimations = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBackAnim, v);
  }

  static Future<void> setArtworkShape(String v) async {
    artworkShapeNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kArtworkShape, v);
  }

  static Future<void> setLyricsPosition(String v) async {
    lyricsStyleNotifier.value = lyricsStyleNotifier.value.copyWith(position: v);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLyricsPos, v);
  }

  static Future<void> setLyricsTextSize(double v) async {
    lyricsStyleNotifier.value = lyricsStyleNotifier.value.copyWith(textSize: v);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kLyricsSize, v);
  }

  static Future<void> setLyricsLineSpacing(double v) async {
    lyricsStyleNotifier.value = lyricsStyleNotifier.value.copyWith(lineSpacing: v);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kLyricsSpacing, v);
  }

  static Future<void> setShowLyricsOnPlayer(bool v) async {
    showLyricsOnPlayerNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kShowLyricsOnPlayer, v);
  }

  static Future<void> setCastIconVisibility(String v) async {
    castIconVisibilityNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCastIconVisibility, v);
  }

  static Future<void> setSwipeToChange(bool v) async {
    swipeToChangeNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSwipeChange, v);
  }

  static Future<void> setShakeToSkip(bool v) async {
    shakeToSkipNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kShakeToSkip, v);
  }

  static const _nativeChannel = MethodChannel('com.aurum.music/media_store');

  static Future<void> setStopOnSwipe(bool v) async {
    stopOnSwipeNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kStopOnSwipe, v);
    await pushStopOnSwipeToNative(v);
  }

  /// Mirrors [stopOnSwipeNotifier] to the native AurumMediaSessionService so
  /// onTaskRemoved (a native Android callback with no Dart running when it
  /// fires) knows whether to stop playback on Recents-swipe. Silently no-ops
  /// if the platform channel call fails — this is a nice-to-have preference,
  /// never worth crashing startup or settings-save over.
  static Future<void> pushStopOnSwipeToNative(bool v) async {
    try {
      await _nativeChannel.invokeMethod('setStopOnTaskRemoved', {'value': v});
    } catch (_) {}
  }

  /// Requests the display's highest available refresh rate (90/120Hz on
  /// supported panels) when enabled, or the platform default when
  /// disabled. Silently no-ops on failure — same reasoning as
  /// pushStopOnSwipeToNative above: a smoothness preference should never
  /// crash Settings if a particular device's display API rejects the call.
  static Future<void> pushHighRefreshRateToNative(bool v) async {
    try {
      await _nativeChannel.invokeMethod('setHighRefreshRate', {'enabled': v});
    } catch (_) {}
  }

  static Future<void> setSwipeSensitivity(double v) async {
    swipeSensitivity = v;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kSwipeSens, v);
  }

  static Future<void> setDynamicPlayerColor(bool v) async {
    dynamicPlayerColorNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDynamicColor, v);
  }

  static Future<void> setShowBlurredBg(bool v) async {
    showBlurredBgNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kShowBlurBg, v);
  }

  static Future<void> setNavBarBlurSigma(double v) async {
    navBarBlurSigmaNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kNavBarBlur, v);
  }

  static Future<void> setMiniPlayerBlurSigma(double v) async {
    miniPlayerBlurSigmaNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kMiniPlayerBlur, v);
  }

  static Future<void> setPlayerBgStyle(String v) async {
    playerBgStyleNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPlayerBgStyle, v);
  }

  /// Effective full-player background style after Battery Saver Mode is
  /// factored in — 'Solid' whenever Battery Saver is active, regardless
  /// of the user's saved [playerBgStyleNotifier] choice, since 'Solid' is
  /// the cheapest of the three to render (no Ken Burns blur, no
  /// breathing gradient). The saved preference itself is untouched, so
  /// once battery recovers this reads back through to exactly what the
  /// user had chosen.
  static String get effectivePlayerBgStyle =>
      batterySaverActiveNotifier.value ? 'Solid' : playerBgStyleNotifier.value;

  /// 'Follow Theme' (default) | 'Blur' | 'Solid' — collapsed mini player
  /// background. 'Solid' renders an opaque flat surface instead of the
  /// glass/blur capsule. Set from Settings → Appearance.
  static final ValueNotifier<String> miniPlayerBgStyleNotifier =
      ValueNotifier<String>('Follow Theme');

  /// If true (default), the full player's background gradient slowly
  /// breathes/shifts. If false, the gradient stays still. Set from
  /// Settings → Appearance → "Background Gradient Animation".
  static final ValueNotifier<bool> bgGradientAnimationNotifier =
      ValueNotifier<bool>(true);

  /// Master animation switch. If false, ALL of Aurum's custom motion is
  /// disabled: page transitions collapse to instant cuts, the player
  /// background gradient and artwork float freeze, and list stagger
  /// animations skip straight to their end state. This takes priority over
  /// the individual back_animations / bg_gradient_animation flags — both
  /// of those are still respected independently when this is on.
  /// Set from Settings → Appearance → "Enable Animations".
  static final ValueNotifier<bool> enableAnimationsNotifier =
      ValueNotifier<bool>(true);

  static Future<void> setMiniPlayerBgStyle(String v) async {
    miniPlayerBgStyleNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMiniPlayerBg, v);
  }

  static Future<void> setBgGradientAnimation(bool v) async {
    bgGradientAnimationNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBgGradAnim, v);
  }

  static Future<void> setEnableAnimations(bool v) async {
    enableAnimationsNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnableAnim, v);
  }

  static Future<void> setBatterySaverEnabled(bool v) async {
    batterySaverEnabledNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBatterySaverEnabled, v);
    // Turning the feature off should immediately drop any active override
    // too — otherwise a user disabling it mid-low-battery would still see
    // animations suppressed until the next battery event happened to fire.
    if (!v) {
      batterySaverActiveNotifier.value = false;
    } else {
      _reevaluateBatterySaver();
    }
  }

  static Future<void> setBatterySaverThreshold(int v) async {
    final clamped = v == 15 ? 15 : 20;
    batterySaverThresholdNotifier.value = clamped;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBatterySaverThreshold, clamped);
    _reevaluateBatterySaver();
  }

  /// Set by BatterySaverController.start() so AudioPrefs (which has no
  /// dependency on that controller) can trigger an immediate
  /// re-evaluation right after a Settings change, without either file
  /// needing to import the other circularly.
  static void Function()? _batterySaverReevaluateHook;
  static void registerBatterySaverReevaluateHook(void Function() hook) {
    _batterySaverReevaluateHook = hook;
  }
  static void _reevaluateBatterySaver() => _batterySaverReevaluateHook?.call();

  static Future<void> setHideListenStats(bool v) async {
    hideListenStats = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kHideStats, v);
  }

  /// Ordered list of Saavn quality strings to try, highest priority first —
  /// driven by [streamQuality] and [dataSaver] (Aurum's own in-app toggle).
  /// Data Saver ON caps at 160kbps (a reasonable data-saving tier, not the
  /// harshest one). Data Saver OFF always reaches for the highest available
  /// bitrate — "Auto" means "give me the best quality this song has," not a
  /// cautious middle ground.
  static List<String> qualityOrder() {
    if (dataSaver) return const ['160kbps', '96kbps', '48kbps', '12kbps'];

    // Phase 5 — 320kbps is premium-only. Free users capped at 160kbps.
    if (!isPremium) {
      switch (streamQuality) {
        case 'Low':
          return const ['12kbps', '48kbps', '96kbps'];
        case 'Medium':
        case 'High':
        case 'Auto':
        default:
          return const ['160kbps', '96kbps', '48kbps', '12kbps'];
      }
    }

    switch (streamQuality) {
      case 'Low':
        return const ['12kbps', '48kbps', '96kbps'];
      case 'Medium':
        return const ['160kbps', '96kbps', '320kbps', '48kbps', '12kbps'];
      case 'High':
      case 'Auto':
      default:
        // Data Saver is off — always reach for the highest bitrate first,
        // regardless of the manual Stream Quality dropdown.
        return const ['320kbps', '160kbps', '96kbps', '48kbps', '12kbps'];
    }
  }
}
