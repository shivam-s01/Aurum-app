// Anonymous usage stats -> Aurum Stats Worker (own Cloudflare Worker + D1).
// Sends only: random install id, event name, song title/artist, app version.
// City/country are derived server-side by Cloudflare; no IP/email/GPS stored.
// Never called while Incognito is ON (see AnalyticsService._log). Fails silent.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class StatsService {
  StatsService._();
  static final StatsService instance = StatsService._();

  static const _url = 'https://aurum-stats.shivamsharma962122.workers.dev/t';
  static const _key = '520eb648b88c6571ffe180adeddb70fc';

  String? _anon;
  String _ver = '';
  Future<void>? _ready;

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      var id = p.getString('stats_anon_id');
      if (id == null) {
        id = const Uuid().v4();
        await p.setString('stats_anon_id', id);
      }
      _anon = id;
      _ver = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
  }

  void send(String ev, Map<String, Object>? params) {
    () async {
      try {
        await (_ready ??= _init());
        final id = _anon;
        if (id == null) return;
        final p = params ?? const <String, Object>{};
        final body = jsonEncode({
          'a': id,
          'e': ev,
          'v': _ver,
          'sid': p['song_id'],
          't': p['song_title'],
          'ar': p['artist'],
          'sc': p['screen_name'],
        });
        await http
            .post(Uri.parse(_url),
                headers: {'content-type': 'application/json', 'x-aurum-key': _key},
                body: body)
            .timeout(const Duration(seconds: 6));
      } catch (_) {}
    }();
  }
}
