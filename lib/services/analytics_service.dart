// Firebase Analytics wrapper. Fails soft (no-op) if Firebase isn't
// configured for the build. Respects Incognito Mode: while incognito is ON,
// collection is switched off entirely (no events, no sessions).
//
// Automatic (no code needed): first_open, session_start, app version, device
// brand/model, OS version, country + city (derived from IP by Google, no
// location permission). Custom events below add song/search/screen insight.

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'audio_prefs.dart';
import 'stats_service.dart';
import 'supabase_tracker.dart';
import 'user_region.dart';

class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  FirebaseAnalytics? _fa;

  Future<void> init() async {
    if (_fa != null) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final fa = FirebaseAnalytics.instance;
      await fa.setAnalyticsCollectionEnabled(!AudioPrefs.incognito);
      await fa.setUserProperty(name: 'app_country', value: UserRegion.code);
      _fa = fa;
    } catch (e) {
      if (kDebugMode) debugPrint('[Aurum] AnalyticsService init failed: $e');
    }
    SupabaseTracker.instance.start();
    _log('app_open');
  }

  /// Called from AudioPrefs.setIncognito — incognito = no tracking at all.
  Future<void> setCollection(bool enabled) async {
    try {
      await _fa?.setAnalyticsCollectionEnabled(enabled);
    } catch (_) {}
  }

  String _cut(String s) => s.length > 100 ? s.substring(0, 100) : s;

  void _log(String name, [Map<String, Object>? params]) {
    if (AudioPrefs.incognito) return;
    StatsService.instance.send(name, params);
    SupabaseTracker.instance.send(name, params);
    final fa = _fa;
    if (fa == null) return;
    fa.logEvent(name: name, parameters: params).catchError((_) {});
  }

  void logSongPlay(Song song) => _log('song_play', {
        'song_id': _cut(song.id),
        'song_title': _cut(song.title),
        'artist': _cut(song.artist),
        'source': song.isLocal ? 'local' : 'online',
      });

  void logSearch(String q) {
    final t = q.trim();
    if (t.isEmpty) return;
    _log('search', {'search_term': _cut(t)});
  }

  void logScreen(String name) => _log('screen_view', {
        'screen_name': name,
        'screen_class': name,
      });

  void logLogin() {
    _log('login', {'method': 'google'});
    SupabaseTracker.instance.onLogin();
  }

  // ── Supabase-only events (not sent to Firebase / Cloudflare worker) ──
  Map<String, Object> _songParams(Song s) => {
        'song_id': _cut(s.id),
        'song_title': _cut(s.title),
        'artist': _cut(s.artist),
        'source': s.isLocal ? 'local' : 'online',
      };

  void _sb(String name, [Map<String, Object>? params]) {
    if (AudioPrefs.incognito) return;
    SupabaseTracker.instance.send(name, params);
  }

  void logSongSkip(Song s) => _sb('song_skip', _songParams(s));
  void logSongComplete(Song s) => _sb('song_complete', _songParams(s));
  void logSongReplay(Song s) => _sb('song_replay', _songParams(s));
  void logSongListened(Song s, int sec) =>
      _sb('song_listened', {..._songParams(s), 'sec': sec});
  void logFavorite(Song s, bool added) =>
      _sb(added ? 'favorite_add' : 'favorite_remove', _songParams(s));

  void logDownload(Song s) => _sb('download_start', _songParams(s));
  void logPlaylistCreate(String name) =>
      _sb('playlist_create', {'name': _cut(name)});
  void logPlaylistAdd(Song s) => _sb('playlist_add_song', _songParams(s));

  void logLogout() {
    _sb('logout');
    SupabaseTracker.instance.flush();
  }

  void logPremium(String planId) =>
      _log('premium_activated', {'plan_id': _cut(planId)});

  void setPremium(bool isPremium) {
    SupabaseTracker.instance.setPremium(isPremium);
    final fa = _fa;
    if (fa == null) return;
    fa.setUserProperty(name: 'is_premium', value: isPremium ? '1' : '0')
        .catchError((_) {});
  }
}
