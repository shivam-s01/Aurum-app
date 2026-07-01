import 'package:flutter/foundation.dart';
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

  /// If true (default), swiping left/right on the full player artwork
  /// skips to the next/previous track. Set from Settings → Player & Audio.
  static final ValueNotifier<bool> swipeToChangeNotifier =
      ValueNotifier<bool>(true);

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

  /// If true, play counts / time-listened are not tracked. Set from
  /// Settings → Privacy.
  static bool hideListenStats = false;

  /// Mirrors PremiumProvider.isPremium for service-layer code (ApiService)
  /// that has no BuildContext. Set by PremiumProvider whenever its value
  /// changes. Default false — never self-grant.
  static bool isPremium = false;

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
  static const _kSwipeChange   = 'swipe_to_change';
  static const _kSwipeSens     = 'swipe_sensitivity';
  static const _kDynamicColor  = 'dynamic_player_color';
  static const _kShowBlurBg    = 'show_blurred_bg';
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
    swipeSensitivity = p.getDouble(_kSwipeSens) ?? swipeSensitivity;
    dynamicPlayerColorNotifier.value = p.getBool(_kDynamicColor) ?? dynamicPlayerColorNotifier.value;
    showBlurredBgNotifier.value = p.getBool(_kShowBlurBg) ?? showBlurredBgNotifier.value;
    playerBgStyleNotifier.value = p.getString(_kPlayerBgStyle) ?? playerBgStyleNotifier.value;
    miniPlayerBgStyleNotifier.value = p.getString(_kMiniPlayerBg) ?? miniPlayerBgStyleNotifier.value;
    bgGradientAnimationNotifier.value = p.getBool(_kBgGradAnim) ?? bgGradientAnimationNotifier.value;
    enableAnimationsNotifier.value = p.getBool(_kEnableAnim) ?? enableAnimationsNotifier.value;
    hideListenStats     = p.getBool(_kHideStats) ?? hideListenStats;
    notifShowPrev       = p.getBool(_kNotifShowPrev) ?? notifShowPrev;
    notifCompact        = (p.getString(_kNotifStyle) ?? 'Expanded') == 'Compact';
    showMediaNotif      = p.getBool(_kShowMediaNotif) ?? showMediaNotif;
    showArtworkNotif    = p.getBool(_kShowArtworkNotif) ?? showArtworkNotif;
    gapless             = p.getBool(_kGapless) ?? gapless;
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

  static Future<void> setSwipeToChange(bool v) async {
    swipeToChangeNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSwipeChange, v);
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

  static Future<void> setPlayerBgStyle(String v) async {
    playerBgStyleNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPlayerBgStyle, v);
  }

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

  static Future<void> setHideListenStats(bool v) async {
    hideListenStats = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kHideStats, v);
  }

  /// Ordered list of Saavn quality strings to try, highest priority first —
  /// driven by [streamQuality] and [dataSaver]. Data Saver always wins and
  /// forces the lowest tier regardless of the manual Stream Quality choice.
  ///
  /// FIX: the old lists put 160kbps/320kbps as fallback entries even in
  /// Data Saver / Low quality mode. Since Saavn doesn't have every bitrate
  /// available for every song, the "lowest quality first" list would often
  /// fail to find 48/96/12kbps and silently fall through to 160kbps or even
  /// 320kbps — quietly burning far more mobile data than the user asked for,
  /// while Data Saver still showed as "on". Low-tier lists now only ever
  /// fall back to other LOW tiers (12/48/96kbps), never to 160/320kbps.
  static List<String> qualityOrder() {
    if (dataSaver) return const ['12kbps', '48kbps', '96kbps'];

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
        return const ['320kbps', '160kbps', '96kbps', '48kbps', '12kbps'];
      case 'Auto':
      default:
        return const ['320kbps', '160kbps', '96kbps', '48kbps', '12kbps'];
    }
  }
}
