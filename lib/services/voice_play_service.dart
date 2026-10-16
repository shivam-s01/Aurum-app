import 'dart:async';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../main.dart' show navigatorKey;
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../screens/library_screen.dart' show PlaylistsScreen, PlaylistDetailScreen;
import '../utils/aurum_transitions.dart' show AurumPageRoute;
import 'api_service.dart';

/// Handles "open Astra Music and play <song>" from Gemini / Google Assistant
/// (android.media.action.MEDIA_PLAY_FROM_SEARCH). Native side: MainActivity.
class VoicePlayService {
  VoicePlayService._();
  static const _ch = MethodChannel('com.aurum.music/voice');
  static bool _started = false;
  static bool _coldStart = true;
  static String _lastQ = '';
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> init() async {
    if (_started) return;
    _started = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'voicePlay') {
        unawaited(_play(call.arguments as String? ?? ''));
      }
      return null;
    });
    try {
      final pending = await _ch.invokeMethod<String>('getPending');
      if (pending != null && pending.isNotEmpty) unawaited(_play(pending));
    } catch (_) {}
  }

  static Future<void> _play(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final now = DateTime.now();
    if (q == _lastQ && now.difference(_lastAt) < const Duration(seconds: 4)) return;
    _lastQ = q;
    _lastAt = now;
    // Cold start: wait for the widget tree + providers (max ~15s).
    for (var i = 0; i < 60 && navigatorKey.currentContext == null; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    try {
      var ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      // Wait (max ~10s) for saved liked songs / playlists to finish loading.
      for (var i = 0; i < 40; i++) {
        final c = navigatorKey.currentContext;
        if (c == null) break;
        ctx = c;
        if (!c.read<FavoritesProvider>().isLoading && !c.read<PlaylistProvider>().isLoading) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }
      if (_coldStart) {
        _coldStart = false;
        await Future.delayed(const Duration(milliseconds: 1200)); // let audio engine settle
      }
      final player = ctx.read<PlayerProvider>();
      final lq = q.toLowerCase();

      // "liked songs" / "favourites" -> play the liked list
      const likedWords = ['liked song', 'favourite', 'favorite', 'my likes', 'pasand'];
      if (likedWords.any(lq.contains)) {
        final favs = ctx.read<FavoritesProvider>().favorites;
        if (favs.isNotEmpty) {
          await player.playSong(favs.first, queue: List.of(favs), index: 0);
          return;
        }
        // no liked songs yet -> fall back to a normal search
        final fb = await ApiService.search('top hindi songs');
        final fl = fb.direct.isNotEmpty ? fb.direct : fb.all;
        if (fl.isNotEmpty) await player.playSong(fl.first, queue: fl, index: 0);
        return;
      }

      // "<playlist name>" -> play that user playlist
      final cleaned = lq
          .replaceAll(RegExp(r'\b(my|the|playlist|play)\b'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleaned == 'playlists' || cleaned == 'all playlists') {
        navigatorKey.currentState?.push(AurumPageRoute(builder: (_) => const PlaylistsScreen()));
        return;
      }
      if (cleaned.isNotEmpty) {
        for (final pl in ctx.read<PlaylistProvider>().playlists) {
          final n = pl.name.toLowerCase().trim();
          if (pl.songs.isNotEmpty && (n == cleaned || (n.length >= 3 && (n.contains(cleaned) || cleaned.contains(n))))) {
            navigatorKey.currentState?.push(
                AurumPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: pl.id)));
            await player.playSong(pl.songs.first, queue: List.of(pl.songs), index: 0);
            return;
          }
        }
      }

      // otherwise: normal song search
      final res = await ApiService.search(q);
      final list = res.direct.isNotEmpty ? res.direct : res.all;
      if (list.isEmpty) return;
      await player.playSong(list.first, queue: list, index: 0);
    } catch (_) {}
  }
}
