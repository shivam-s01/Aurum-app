// Usage tracking -> Supabase (app_events + devices). Fails silent, batched,
// offline-safe. Incognito ON = nothing is recorded or sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'audio_prefs.dart';
import 'stats_service.dart';
import 'user_region.dart';

class SupabaseTracker with WidgetsBindingObserver {
  SupabaseTracker._();
  static final SupabaseTracker instance = SupabaseTracker._();

  static const _known = {'song_id', 'song_title', 'artist', 'screen_name'};

  final List<Map<String, dynamic>> _buf = [];
  Timer? _timer;
  bool _started = false;
  bool _flushing = false;
  bool? _premium;

  String _session = const Uuid().v4();
  String? _anon;
  String _ver = '';
  String? _brand, _model, _os;
  int? _sdk;
  Map<String, Object>? _hw;
  Map<String, Object>? _geo;
  DateTime _fgAt = DateTime.now();
  DateTime? _bgAt;

  SupabaseClient get _c => Supabase.instance.client;

  /// Call once (AnalyticsService.init does it).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      WidgetsBinding.instance.addObserver(this);
      _anon = await StatsService.instance.anonId();
      _ver = (await PackageInfo.fromPlatform()).version;
      await _loadDevice();
    } catch (_) {}
    await _beginSession();
  }

  Future<void> _loadDevice() async {
    final hw = <String, Object>{};
    try {
      if (Platform.isAndroid) {
        final a = await DeviceInfoPlugin().androidInfo;
        _brand = a.brand;
        _model = a.model;
        _os = a.version.release;
        _sdk = a.version.sdkInt;
        hw['manufacturer'] = a.manufacturer;
        hw['device'] = a.device;
        hw['product'] = a.product;
        hw['hardware'] = a.hardware;
        hw['board'] = a.board;
        hw['is_physical'] = a.isPhysicalDevice;
        hw['abis'] = a.supportedAbis;
        final sp = a.version.securityPatch;
        if (sp != null) hw['security_patch'] = sp;
      }
    } catch (_) {}
    try {
      final v = WidgetsBinding.instance.platformDispatcher.views.first;
      hw['screen_w'] = v.physicalSize.width.round();
      hw['screen_h'] = v.physicalSize.height.round();
      hw['pixel_ratio'] = v.devicePixelRatio;
    } catch (_) {}
    _hw = hw.isEmpty ? null : hw;
  }

  // ── Geo (city etc.) from public IP — free HTTPS lookup, no permission ──
  Future<Map<String, Object>?> _fetchGeo() async {
    try {
      final r = await http
          .get(Uri.parse('https://ipwho.is/'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        if (j is Map && j['success'] == true) {
          return _clean({
            'ip': j['ip'],
            'city': j['city'],
            'region': j['region'],
            'country': j['country'],
            'country_code': j['country_code'],
            'lat': j['latitude'],
            'lon': j['longitude'],
            'timezone': j['timezone'] is Map ? j['timezone']['id'] : null,
            'isp': j['connection'] is Map ? j['connection']['isp'] : null,
          });
        }
      }
    } catch (_) {}
    try {
      final r = await http
          .get(Uri.parse('https://ipapi.co/json/'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        if (j is Map && j['error'] != true) {
          return _clean({
            'ip': j['ip'],
            'city': j['city'],
            'region': j['region'],
            'country': j['country_name'],
            'country_code': j['country_code'],
            'lat': j['latitude'],
            'lon': j['longitude'],
            'timezone': j['timezone'],
            'isp': j['org'],
          });
        }
      }
    } catch (_) {}
    return null;
  }

  Map<String, Object> _clean(Map<String, Object?> m) {
    final o = <String, Object>{};
    m.forEach((k, v) {
      if (v != null) o[k] = v;
    });
    return o;
  }

  /// New app session: refresh location, register device, log session_info.
  Future<void> _beginSession() async {
    if (AudioPrefs.incognito) return;
    _geo = await _fetchGeo() ?? _geo;
    await _registerDevice(count: true);
    String net = '';
    try {
      final r = await Connectivity().checkConnectivity();
      net = r.map((e) => e.name).join(',');
    } catch (_) {}
    final now = DateTime.now();
    send('session_info', _clean({
      'net': net,
      'city': _geo?['city'],
      'region': _geo?['region'],
      'country': _geo?['country'],
      'ip': _geo?['ip'],
      'isp': _geo?['isp'],
      'tz': now.timeZoneName,
      'tz_offset_min': now.timeZoneOffset.inMinutes,
      'locale': PlatformDispatcherLocale.get(),
    }));
  }

  Future<void> _registerDevice({required bool count}) async {
    if (AudioPrefs.incognito) return;
    try {
      _anon ??= await StatsService.instance.anonId();
      if (_anon == null) return;
      await _c.rpc('register_device', params: {
        'p_anon': _anon,
        'p_brand': _brand,
        'p_model': _model,
        'p_os': _os,
        'p_sdk': _sdk,
        'p_ver': _ver,
        'p_country': UserRegion.code,
        'p_locale': PlatformDispatcherLocale.get(),
        'p_premium': _premium,
        'p_count': count,
        'p_geo': _geo,
        'p_hw': _hw,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[Tracker] register error: $e');
    }
  }

  void onLogin() => _registerDevice(count: false);

  void setPremium(bool v) {
    if (_premium == v) return;
    _premium = v;
    if (_started) _registerDevice(count: false);
  }

  void send(String ev, Map<String, Object>? p) {
    if (AudioPrefs.incognito) return;
    try {
      final extra = <String, Object?>{};
      if (p != null) {
        p.forEach((k, v) {
          if (!_known.contains(k)) extra[k] = v;
        });
      }
      String? uid;
      try {
        uid = _c.auth.currentUser?.id;
      } catch (_) {}
      _buf.add({
        'anon_id': _anon,
        'user_id': uid,
        'session_id': _session,
        'event': ev,
        'song_id': p?['song_id'],
        'title': p?['song_title'],
        'artist': p?['artist'],
        'screen': p?['screen_name'],
        'extra': extra.isEmpty ? null : extra,
        'app_version': _ver,
        'platform': defaultTargetPlatform.name,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (_buf.length >= 15) {
        flush();
      } else {
        _timer ??= Timer(const Duration(seconds: 10), flush);
      }
    } catch (_) {}
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_flushing || _buf.isEmpty) return;
    _flushing = true;
    final rows = List<Map<String, dynamic>>.from(_buf);
    _buf.clear();
    try {
      _anon ??= await StatsService.instance.anonId();
      if (_anon == null) throw 'no anon id';
      for (final r in rows) {
        r['anon_id'] ??= _anon;
      }
      try {
        await _c.from('app_events').insert(rows);
      } catch (_) {
        // e.g. user signed out before flush -> keep data, drop user link
        // (anon_id still ties it to the same install).
        final retry = rows.map((r) => {...r, 'user_id': null}).toList();
        await _c.from('app_events').insert(retry);
      }
    } catch (_) {
      // offline / error: put back (capped) and retry on next flush
      if (_buf.length + rows.length < 500) {
        _buf.insertAll(0, rows);
      }
      _timer ??= Timer(const Duration(seconds: 30), flush);
    } finally {
      _flushing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    if (state == AppLifecycleState.resumed) {
      final now = DateTime.now();
      final away = _bgAt == null ? Duration.zero : now.difference(_bgAt!);
      _fgAt = now;
      if (away > const Duration(minutes: 30)) {
        _session = const Uuid().v4();
        send('app_open', null);
        _beginSession();
      } else if (_bgAt != null) {
        send('app_foreground', null);
      }
    } else if (state == AppLifecycleState.paused) {
      _bgAt = DateTime.now();
      send('app_background',
          {'session_sec': _bgAt!.difference(_fgAt).inSeconds});
      flush();
    } else if (state == AppLifecycleState.detached) {
      flush();
    }
  }
}

/// Small helper so we don't need an extra import in callers.
class PlatformDispatcherLocale {
  static String? get() {
    try {
      return WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag();
    } catch (_) {
      return null;
    }
  }
}
