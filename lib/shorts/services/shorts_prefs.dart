import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for Shorts onboarding + lightweight interaction
/// signals (likes/skips/replays). Fully isolated key namespace
/// ('shorts_*') so it never collides with existing AudioPrefs keys.
class ShortsPrefs {
  ShortsPrefs._();

  static const _kOnboarded = 'shorts_onboarded';
  static const _kLanguages = 'shorts_languages';
  static const _kCategories = 'shorts_categories';
  static const _kLiked = 'shorts_liked_ids';
  static const _kSaved = 'shorts_saved_ids';
  static const _kSkipped = 'shorts_skipped_ids';
  static const _kReplayCounts = 'shorts_replay_counts'; // json map id->count
  static const _kArtistFreq = 'shorts_artist_freq'; // json map artist->count
  static const _kWifiOnlyVideo = 'shorts_wifi_only_video';

  static SharedPreferences? _prefsCache;

  static Future<SharedPreferences> get _prefs async {
    return _prefsCache ??= await SharedPreferences.getInstance();
  }

  // ── Onboarding ──────────────────────────────────────────────
  static Future<bool> isOnboarded() async {
    final p = await _prefs;
    return p.getBool(_kOnboarded) ?? false;
  }

  static Future<void> setOnboarded() async {
    final p = await _prefs;
    await p.setBool(_kOnboarded, true);
  }

  static Future<List<String>> getLanguages() async {
    final p = await _prefs;
    return p.getStringList(_kLanguages) ?? const [];
  }

  static Future<void> setLanguages(List<String> langs) async {
    final p = await _prefs;
    await p.setStringList(_kLanguages, langs);
  }

  static Future<List<String>> getCategories() async {
    final p = await _prefs;
    return p.getStringList(_kCategories) ?? const [];
  }

  static Future<void> setCategories(List<String> cats) async {
    final p = await _prefs;
    await p.setStringList(_kCategories, cats);
  }

  // ── Interaction signals ─────────────────────────────────────
  static Future<Set<String>> getLiked() async {
    final p = await _prefs;
    return (p.getStringList(_kLiked) ?? const []).toSet();
  }

  static Future<void> toggleLiked(String id) async {
    final p = await _prefs;
    final set = (p.getStringList(_kLiked) ?? const []).toSet();
    if (set.contains(id)) {
      set.remove(id);
    } else {
      set.add(id);
    }
    await p.setStringList(_kLiked, set.toList());
  }

  static Future<bool> isLiked(String id) async {
    final liked = await getLiked();
    return liked.contains(id);
  }

  static Future<Set<String>> getSaved() async {
    final p = await _prefs;
    return (p.getStringList(_kSaved) ?? const []).toSet();
  }

  static Future<void> toggleSaved(String id) async {
    final p = await _prefs;
    final set = (p.getStringList(_kSaved) ?? const []).toSet();
    if (set.contains(id)) {
      set.remove(id);
    } else {
      set.add(id);
    }
    await p.setStringList(_kSaved, set.toList());
  }

  static Future<bool> isSaved(String id) async {
    final saved = await getSaved();
    return saved.contains(id);
  }

  static Future<void> addSkipped(String id) async {
    final p = await _prefs;
    final set = (p.getStringList(_kSkipped) ?? const []).toSet();
    set.add(id);
    // Cap growth — keep most recent 500 skipped ids.
    final list = set.toList();
    final trimmed =
        list.length > 500 ? list.sublist(list.length - 500) : list;
    await p.setStringList(_kSkipped, trimmed);
  }

  static Future<Set<String>> getSkipped() async {
    final p = await _prefs;
    return (p.getStringList(_kSkipped) ?? const []).toSet();
  }

  static Future<void> incrementReplay(String id) async {
    final p = await _prefs;
    final raw = p.getString(_kReplayCounts);
    final map = raw != null
        ? Map<String, int>.from(jsonDecode(raw) as Map)
        : <String, int>{};
    map[id] = (map[id] ?? 0) + 1;
    await p.setString(_kReplayCounts, jsonEncode(map));
  }

  static Future<Map<String, int>> getReplayCounts() async {
    final p = await _prefs;
    final raw = p.getString(_kReplayCounts);
    if (raw == null) return {};
    return Map<String, int>.from(jsonDecode(raw) as Map);
  }

  static Future<void> bumpArtist(String artist) async {
    final p = await _prefs;
    final raw = p.getString(_kArtistFreq);
    final map = raw != null
        ? Map<String, int>.from(jsonDecode(raw) as Map)
        : <String, int>{};
    map[artist] = (map[artist] ?? 0) + 1;
    await p.setString(_kArtistFreq, jsonEncode(map));
  }

  static Future<Map<String, int>> getArtistFreq() async {
    final p = await _prefs;
    final raw = p.getString(_kArtistFreq);
    if (raw == null) return {};
    return Map<String, int>.from(jsonDecode(raw) as Map);
  }

  // ── Background video (Shorts visual clip) settings ─────────────
  // Defaults to true — a paid, premium-feeling app should never
  // silently burn a user's mobile data on background video without
  // an explicit opt-in.
  static Future<bool> getWifiOnlyVideo() async {
    final p = await _prefs;
    return p.getBool(_kWifiOnlyVideo) ?? true;
  }

  static Future<void> setWifiOnlyVideo(bool value) async {
    final p = await _prefs;
    await p.setBool(_kWifiOnlyVideo, value);
  }

  /// For settings/debug — wipe all shorts prefs (not onboarding data
  /// from other features).
  static Future<void> resetAll() async {
    final p = await _prefs;
    await p.remove(_kOnboarded);
    await p.remove(_kLanguages);
    await p.remove(_kCategories);
    await p.remove(_kLiked);
    await p.remove(_kSaved);
    await p.remove(_kSkipped);
    await p.remove(_kReplayCounts);
    await p.remove(_kArtistFreq);
    await p.remove(_kWifiOnlyVideo);
  }
}
