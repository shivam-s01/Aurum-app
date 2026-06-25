import 'package:shared_preferences/shared_preferences.dart';

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

  /// If true, the current session's plays are not added to history and
  /// don't feed the recommendation engine. Set from Settings → Privacy.
  static bool incognito = false;

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
  static const _kHideStats     = 'hide_listen_stats';

  /// Restore all values from disk. Call once at startup (from the audio
  /// handler's _init()).
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    streamQuality       = p.getString(_kStreamQuality) ?? streamQuality;
    dataSaver           = p.getBool(_kDataSaver) ?? dataSaver;
    pauseOnCall         = p.getBool(_kPauseOnCall) ?? pauseOnCall;
    duckOnNotifications = p.getBool(_kDuckNotif) ?? duckOnNotifications;
    incognito           = p.getBool(_kIncognito) ?? incognito;
    hideListenStats     = p.getBool(_kHideStats) ?? hideListenStats;
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
