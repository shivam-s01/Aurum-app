// ═══════════════════════════════════════════════════════════════════════════
// FILE: lib/services/jam_service.dart
// DESCRIPTION: "Astra Jam" — Listen Together. Up to [maxMembers] phones play
//   the same song at the same moment, each streaming on its own.
//
// TRANSPORT: one WebSocket per room to the Astra Jam server (Cloudflare
//   Worker + Durable Object, see jam-server/PROTOCOL.md). The server owns the
//   room: members, host, join approval, kick, host hand-over, 10-minute seat
//   resume, song suggestions, and ONE shared clock. Audio never travels
//   through it — every phone resolves and streams the song itself.
//
// ROOM FLOW (same as Aura Music's Listen Together):
//   • Host creates a room → shares the code / link.
//   • A guest opens it (preview), taps Join → the HOST gets a request and
//     approves or rejects it (or "auto-approve" is on).
//   • Host can kick / block / hand the Jam to someone else. Guests can
//     suggest songs; the host approves them into "up next".
//   • Drop the connection (tunnel, app killed) and you are back in the same
//     seat within 10 minutes.
//
// HOW IT STAYS IN SYNC (unchanged engine):
//   1. Clock sync  — every phone measures its offset to the SERVER clock
//      with ping/pong (lowest-RTT samples win), so everybody — host included
//      — shares one timeline.
//   2. Barrier     — on every song change the host says "load"; every phone
//      loads the song PAUSED, buffers, answers "ready"; only then the host
//      says "go at T+0.9 s". That is why playback starts without stutter.
//   3. Drift fix   — a guest that is a little off nudges its speed ±1.5-3 %
//      (inaudible); a guest that is far off seeks once.
//   4. Stall rule  — if one phone stalls, the room waits for it up to 4 s,
//      then carries on; that phone re-syncs by itself when it recovers.
//   5. Up next     — the host's queue is mirrored to every guest live.
//
// NOTE: only online songs can be shared (local files exist on one phone).
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import 'auth_service.dart';
import 'native_engine_bridge.dart';
import 'notification_service.dart';

/// idle → connecting → previewing → requesting (waiting for the host to
/// approve) → inRoom.
enum JamPhase { idle, connecting, previewing, requesting, inRoom }

/// Short notice codes the UI turns into (localised) text.
enum JamNotice {
  none,
  roomNotFound,
  roomFull,
  connectionFailed,
  localSongSkipped,
  youAreHostNow,
  waitingForFriend,
  reconnecting,
  hostEnded,
  joinRejected,
  requestTimeout,
  kicked,
  sessionExpired,
  joinRequest,
  suggestionIncoming,
  suggestionSent,
  suggestionApproved,
  suggestionRejected,
}

class JamMember {
  final String id;
  final String name;
  final String? avatar;
  final bool isHost;
  final int joinedAt;
  final String status; // ok | buffering | syncing
  final bool connected; // false while the phone is reconnecting
  const JamMember({
    required this.id,
    required this.name,
    this.avatar,
    required this.isHost,
    required this.joinedAt,
    required this.status,
    this.connected = true,
  });
}

/// A guest waiting at the door (host only).
class JamJoinRequest {
  final String userId;
  final String username;
  final String? avatar;
  final int at;
  const JamJoinRequest({required this.userId, required this.username, this.avatar, required this.at});
}

/// "Play this next?" from a guest (host only).
class JamSuggestion {
  final String id;
  final String fromUserId;
  final String fromUsername;
  final Song song;
  const JamSuggestion({
    required this.id,
    required this.fromUserId,
    required this.fromUsername,
    required this.song,
  });
}

class _Timeline {
  String? songId;
  int posMs = 0; // position at [atHost]
  int atHost = 0; // host-clock ms
  bool playing = false;
}

class JamService extends ChangeNotifier {
  JamService._();
  static final JamService instance = JamService._();

  // ── Tunables ────────────────────────────────────────────────────────────
  static const int maxMembers = 4;
  static const String codePrefix = 'ASTRA-';
  static const String linkBase = 'https://astra.mmusic.workers.dev/jam/';
  /// Jam server (Cloudflare Worker). The room code is added as ?room=CODE.
  /// Own-server option is switched OFF (UI hidden, saved URLs ignored).
  /// Set to true (and ship an update) to bring it back.
  static const bool allowCustomServer = false;
  static const String defaultServerUrl = 'wss://astra-jam.shivamsharma962122.workers.dev/jam/ws';
  static const int _sessionGraceMs = 10 * 60 * 1000; // seat is held this long
  static const int _approvalTimeoutMs = 75000; // how long a guest waits for the host
  static const String _alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  static const int _startDelayMs = 900; // go-signal lead time (minimum)
  static const int _maxStartDelayMs = 2800; // grows with the slowest guest's RTT
  static const int _barrierTimeoutMs = 15000; // slow phones get time to buffer
  static const int _stallHoldMs = 4000;
  // The native engine reports its position once per second and the reading
  // carries ~30-150 ms of channel/scheduling noise. Reacting to every blip
  // (old limits: 35 ms / 200 ms) made guests change speed and seek all the
  // time, and each setPlaybackSpeed()/seek() is an audible glitch. So: wide
  // dead-zone, median of recent samples, rare and gentle corrections.
  static const int _driftIgnoreMs = 90;
  static const int _driftHardSeekMs = 350; // only a real, persistent gap is worth a seek
  static const int _speedChangeGapMs = 5000; // at most one speed change per 5 s
  static const int _maxQueueSent = 25;

  // ── Public state ────────────────────────────────────────────────────────
  JamPhase _phase = JamPhase.idle;
  JamPhase get phase => _phase;
  bool get inRoom => _phase == JamPhase.inRoom;

  String _code = ''; // 6 chars, without prefix
  String get roomCode => _code;
  String get fullCode => '$codePrefix$_code';
  String get shareLink => '$linkBase$_code';

  String _roomName = '';
  String get roomName => _roomName;

  bool _isHost = false;
  bool get isHost => _isHost;

  List<JamMember> _members = const [];
  List<JamMember> get members => _members;

  JamNotice _notice = JamNotice.none;
  JamNotice get notice => _notice;
  void clearNotice() {
    if (_notice != JamNotice.none) {
      _notice = JamNotice.none;
      notifyListeners();
    }
  }

  // Preview (join-by-link, before the user taps Join)
  String previewRoomName = '';
  String previewHostName = '';
  String previewSong = '';
  String? previewHostAvatar;
  List<String?> previewAvatars = const [];
  int previewCount = 0;

  /// One short line about the last connect attempt (socket status, server
  /// reply…). Shown in small text on the error card so a failure can be
  /// diagnosed from a screenshot.
  String debugInfo = '';

  /// Live sync error of THIS phone vs the room, in ms (+ = ahead). For the
  /// small status line / debug overlay.
  int _driftMs = 0;
  int get driftMs => _driftMs;

  /// Manual offset (Bluetooth earbuds delay): + plays earlier. Persisted.
  int _nudgeMs = 0;
  int get nudgeMs => _nudgeMs;

  /// Mirrors what the engine says right now.
  String _myStatus = 'ok';
  String get myStatus => _myStatus;

  String get myId => _myId;
  String get myName => _myName;

  // ── Internals ───────────────────────────────────────────────────────────
  PlayerProvider? _player;
  final NativeAudioEngine _engine = NativeAudioEngine();
  StreamSubscription<NativeEngineState>? _engineSub;

  // transport
  String _serverUrl = defaultServerUrl;
  WebSocket? _ws;
  int _wsGen = 0; // invalidates callbacks from an older socket
  bool _wsOpen = false;
  int _lastServerMsgAt = 0;
  String? _sessionToken;
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  int _disconnectedAt = 0;
  Timer? _reconnectTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Completer<Map<String, dynamic>>? _reply; // the one request we are waiting on
  Set<String> _replyTypes = const {};

  // live "up next" mirroring
  String _lastQueueKey = '';
  Timer? _queueTimer;
  Timer? _queueRetry;
  Map<String, dynamic>? _lastQueueMsg;
  bool _queueApplying = false;

  // my identity — the server assigns the real id when I enter a room
  late String _myId = const Uuid().v4().substring(0, 8);
  String _myName = 'Guest';
  String? _myAvatar;
  int _joinedAt = 0;

  // clock
  int _offsetMs = 0; // hostClock - localClock
  final List<List<int>> _clockSamples = []; // [rtt, offset]
  Timer? _pingTimer;
  int _pingsLeftInBurst = 0;

  // timeline (host clock)
  final _Timeline _tl = _Timeline();

  // engine mirror
  NativeEngineState _es = const NativeEngineState();
  int _esAtLocal = 0;
  int _lastDurMs = 0;
  int _prevDurMs = 0;
  String? _prevSongId;
  int _prevPosMs = 0;

  // loading barrier
  int _lid = 0; // current load id
  final Map<int, Set<String>> _ready = {};
  Completer<void>? _barrierWake;
  bool _loading = false; // this phone is inside _applyLoad
  int _busyUntil = 0; // host ignores its own engine echoes until then

  // scheduled start
  Timer? _goTimer;

  // stall hold (host side)
  final Set<String> _stalled = {};
  final Map<String, int> _lastHoldAt = {}; // guest id → when it last paused the room
  Timer? _holdTimer;
  bool _inHold = false;
  int _stallSince = 0;
  bool _sentWait = false;
  final Map<String, int> _guestRtt = {}; // guest id → its best clock-sync RTT (ms)
  Timer? _trackTimer;

  // timers
  Timer? _hbTimer;
  Timer? _busyRecheck;
  Timer? _driftTimer;
  Timer? _peekTimer;

  /// Bumped by every leave() and every new create/peek. A create/peek that
  /// finds the number changed was cancelled (user tapped Cancel while
  /// connecting) and must stop without touching state.
  int _opSeq = 0;
  int _graceUntil = 0;
  int _songMismatchSince = 0;
  double _curSpeed = 1.0;
  final List<int> _driftSamples = []; // recent raw drift readings (median = real drift)
  int _lastSpeedChangeAt = 0;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void _wakeBarrier() {
    final c = _barrierWake;
    if (c != null && !c.isCompleted) c.complete();
  }
  /// The shared timeline: the SERVER clock, for host and guests alike.
  int get _hostNow => _now() + _offsetMs;

  int _bestRtt() {
    if (_clockSamples.isEmpty) return 0;
    var b = _clockSamples.first[0];
    for (final s in _clockSamples) {
      if (s[0] < b) b = s[0];
    }
    return b;
  }

  /// Go-signal lead time: enough for the slowest guest's network round trip.
  int get _goDelayMs {
    if (_alone) return 120;
    var worst = 0;
    for (final r in _guestRtt.values) {
      if (r > worst) worst = r;
    }
    return (_startDelayMs + worst).clamp(_startDelayMs, _maxStartDelayMs).toInt();
  }

  // ══════════════════════════════════════════════════════════════════════
  // Setup
  // ══════════════════════════════════════════════════════════════════════
  /// Safe to call many times; wires the player once.
  void attach(PlayerProvider player) {
    _player = player;
    _engineSub ??= _engine.stateStream.listen(_onEngineState);
  }

  Future<void> _loadPrefs() async {
    await loadSettings();
    final dn = (AuthService.instance.displayName ?? '').trim();
    final auto = dn.isEmpty ? 'Guest ${_myId.substring(0, 3).toUpperCase()}' : dn.split(' ').first;
    _myName = _customName.isNotEmpty ? _customName : auto;
    if (_myName.length > 14) _myName = _myName.substring(0, 14);
    _myAvatar = AuthService.instance.avatarUrl;
  }

  Future<void> setNudge(int ms) async {
    _nudgeMs = ms.clamp(-400, 400).toInt();
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('jam_nudge_ms', _nudgeMs);
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════
  // Codes
  // ══════════════════════════════════════════════════════════════════════
  static String _randomCode() {
    final r = Random.secure();
    return List.generate(6, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
  }

  /// Accepts "ASTRA-K7X2QP", "k7x2qp", a full link, or "astra://jam/K7X2QP".
  /// Returns the 6-char code or null.
  static String? parseCode(String raw) {
    var s = raw.trim().toUpperCase();
    if (s.isEmpty) return null;
    // A whole pasted invite ("Rahul's Jam — Astra Jam\nCode: ASTRA-K7X2QP\nhttps://…")
    // → pull the code out of it first.
    final found = extractCode(s);
    if (found != null) return found;
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);
    s = s.replaceAll('ASTRA-', '').replaceAll('-', '').replaceAll(' ', '');
    s = s.split('?').first;
    if (s.length != 6) return null;
    for (final c in s.split('')) {
      if (!_alphabet.contains(c)) return null;
    }
    return s;
  }

  /// Finds "ASTRA-XXXXXX" or ".../jam/XXXXXX" anywhere inside [text].
  /// Used for clipboard auto-fill and for pasted invites. Null if none.
  static String? extractCode(String text) {
    final t = text.toUpperCase();
    final m = RegExp('ASTRA-([$_alphabet]{6})(?![$_alphabet])').firstMatch(t) ??
        RegExp('/JAM/([$_alphabet]{6})(?![$_alphabet])').firstMatch(t);
    return m?.group(1);
  }

  /// Called when the Jam page opens: resolves the server's address (DNS) so
  /// the websocket handshake is faster by the time the user taps Join.
  void warmUp() {
    try {
      final host = Uri.parse(_serverUrl).host;
      if (host.isNotEmpty) InternetAddress.lookup(host).then((_) {}, onError: (_) {});
    } catch (_) {}
  }

  static String sanitizeRoomName(String raw) {
    var s = raw.replaceAll(RegExp(r'[\n\r\t]'), ' ').trim();
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
    if (s.length > 24) s = s.substring(0, 24).trim();
    return s;
  }


  // ══════════════════════════════════════════════════════════════════════
  // Settings (persisted)
  // ══════════════════════════════════════════════════════════════════════
  bool _autoApprove = false;
  bool get autoApprove => _autoApprove;
  String _customName = '';
  String get customName => _customName;
  Set<String> _blocked = <String>{};
  List<String> get blockedUsers => (_blocked.toList()..sort());
  bool _prefsLoaded = false;

  /// Loads every Jam setting once (safe to call repeatedly).
  Future<void> loadSettings() async {
    if (_prefsLoaded) return;
    try {
      final sp = await SharedPreferences.getInstance();
      _autoApprove = sp.getBool('jam_auto_approve') ?? false;
      _customName = (sp.getString('jam_name') ?? '').trim();
      _blocked = (sp.getStringList('jam_blocked') ?? const <String>[]).toSet();
      final url = (sp.getString('jam_server_url') ?? '').trim();
      _serverUrl = (!allowCustomServer || url.isEmpty) ? defaultServerUrl : url;
      _nudgeMs = (sp.getInt('jam_nudge_ms') ?? 0).clamp(-400, 400).toInt();
      _prefsLoaded = true;
    } catch (_) {}
  }

  Future<void> setAutoApprove(bool v) async {
    _autoApprove = v;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('jam_auto_approve', v);
    } catch (_) {}
  }

  Future<void> setCustomName(String v) async {
    var s = v.replaceAll(RegExp(r'[\n\r\t]'), ' ').trim();
    if (s.length > 14) s = s.substring(0, 14).trim();
    _customName = s;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('jam_name', s);
    } catch (_) {}
  }

  String get serverUrl => _serverUrl;
  bool get hasCustomServer => _serverUrl != defaultServerUrl;
  /// Only what the user typed themselves; empty when the built-in server is used.
  String get customServerUrl => hasCustomServer ? _serverUrl : '';
  Future<void> setServerUrl(String v) async {
    if (!allowCustomServer) return;
    final s = v.trim();
    _serverUrl = (s.startsWith('ws://') || s.startsWith('wss://')) ? s : defaultServerUrl;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      if (_serverUrl == defaultServerUrl) {
        await sp.remove('jam_server_url');
      } else {
        await sp.setString('jam_server_url', _serverUrl);
      }
    } catch (_) {}
  }

  Future<void> _saveBlocked() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList('jam_blocked', _blocked.toList());
    } catch (_) {}
  }

  /// Host: never see this person's join requests / suggestions again. If they
  /// are in the room right now they are removed too.
  void blockUser(String username) {
    final key = username.trim().toLowerCase();
    if (key.isEmpty) return;
    _blocked.add(key);
    unawaited(_saveBlocked());
    _pending = _pending.where((r) => r.username.trim().toLowerCase() != key).toList();
    _suggestions = _suggestions.where((s) => s.fromUsername.trim().toLowerCase() != key).toList();
    if (_isHost && _phase == JamPhase.inRoom) {
      for (final m in _members) {
        if (m.id != _myId && m.name.trim().toLowerCase() == key) kickUser(m.id);
      }
    }
    notifyListeners();
  }

  void unblockUser(String username) {
    _blocked.remove(username.trim().toLowerCase());
    unawaited(_saveBlocked());
    notifyListeners();
  }

  bool isBlocked(String username) => _blocked.contains(username.trim().toLowerCase());

  // ── Session resume (survives app kill; the server holds the seat 10 min) ──
  Future<void> _saveSession() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final t = _sessionToken;
      if (t == null || _code.isEmpty) return;
      await sp.setString('jam_sess_token', t);
      await sp.setString('jam_sess_code', _code);
      await sp.setBool('jam_sess_host', _isHost);
      await sp.setInt('jam_sess_ts', _now());
    } catch (_) {}
  }

  Future<void> _clearSession() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove('jam_sess_token');
      await sp.remove('jam_sess_code');
      await sp.remove('jam_sess_host');
      await sp.remove('jam_sess_ts');
    } catch (_) {}
  }

  /// Room code of a Jam this phone can still rejoin (left it by accident,
  /// app was killed, phone restarted …), or null.
  Future<String?> savedSessionCode() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final token = sp.getString('jam_sess_token') ?? '';
      final code = sp.getString('jam_sess_code') ?? '';
      final ts = sp.getInt('jam_sess_ts') ?? 0;
      if (token.isEmpty || code.isEmpty) return null;
      if (_now() - ts > _sessionGraceMs) {
        await _clearSession();
        return null;
      }
      return code;
    } catch (_) {
      return null;
    }
  }

  Future<void> forgetSavedSession() => _clearSession();

  Future<bool> resumeSession() async {
    if (_phase != JamPhase.idle) return false;
    String token = '';
    String code = '';
    try {
      final sp = await SharedPreferences.getInstance();
      token = sp.getString('jam_sess_token') ?? '';
      code = sp.getString('jam_sess_code') ?? '';
      final ts = sp.getInt('jam_sess_ts') ?? 0;
      if (token.isEmpty || code.isEmpty || _now() - ts > _sessionGraceMs) {
        await _clearSession();
        _fail(JamNotice.sessionExpired);
        return false;
      }
    } catch (_) {
      _fail(JamNotice.sessionExpired);
      return false;
    }
    await _loadPrefs();
    final op = ++_opSeq;
    _phase = JamPhase.connecting;
    _notice = JamNotice.none;
    notifyListeners();

    final ok = await _connect(code, timeoutSec: 15);
    if (await _superseded(op)) return false;
    if (!ok) {
      await _closeWs();
      _fail(JamNotice.connectionFailed);
      return false;
    }
    final r = await _request('reconnect', {'session_token': token}, {'reconnected'}, timeoutMs: 9000);
    if (await _superseded(op)) return false;
    if (r == null || r['type'] != 'reconnected') {
      final expired = r != null && r['type'] == 'error' && (r['code'] ?? '') != 'closed';
      if (expired) await _clearSession();
      await _closeWs();
      _fail(expired ? JamNotice.sessionExpired : JamNotice.connectionFailed);
      return false;
    }
    _code = code;
    _sessionToken = token;
    _myId = (r['user_id'] ?? _myId).toString();
    _isHost = r['is_host'] == true;
    _joinedAt = _now();
    _phase = JamPhase.inRoom;
    _enterRoomCommon();
    final st = r['state'];
    if (st is Map) _applyRoomState(Map<String, dynamic>.from(st));
    if (_isHost) {
      _seedTimelineFromEngine();
    } else {
      _send({'t': 'hello'});
    }
    notifyListeners();
    return true;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Create / peek / join / leave
  // ══════════════════════════════════════════════════════════════════════
  /// True when this create/peek/join was cancelled or replaced while it was
  /// awaiting. Closes the half-open socket only if nothing newer owns it.
  Future<bool> _superseded(int op) async {
    if (op == _opSeq) return false;
    if (_phase == JamPhase.idle) await _closeWs();
    return true;
  }

  /// Everything that is identical when we (re-)enter a room, as host or guest.
  void _enterRoomCommon() {
    _reconnecting = false;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _lastServerMsgAt = _now();
    _jamBuffer(true);
    _startRoomTimers();
    _startClockSync();
    _startConnectivityWatch();
    unawaited(_saveSession());
    _track();
  }

  Future<bool> createRoom(String roomName) async {
    if (_phase != JamPhase.idle) await leave(silent: true);
    await _loadPrefs();
    final op = ++_opSeq;
    _phase = JamPhase.connecting;
    _notice = JamNotice.none;
    notifyListeners();

    final clean = sanitizeRoomName(roomName);
    final name = clean.isEmpty ? '$_myName’s Jam' : clean;
    final tried = <String>[];

    // A random 6-char code collides ~never; the server says "room_exists"
    // if it does, and we simply draw another one.
    for (var attempt = 0; attempt < 3; attempt++) {
      final code = _randomCode();
      final ok = await _connect(code, timeoutSec: attempt == 0 ? 15 : 10);
      if (await _superseded(op)) return false;
      if (!ok) {
        tried.add('ws:fail');
        await _closeWs();
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
          if (await _superseded(op)) return false;
          continue;
        }
        break;
      }
      final r = await _request(
        'create_room',
        {'username': _myName, 'avatar': _myAvatar, 'room_name': name},
        {'room_created'},
        timeoutMs: 10000,
      );
      if (await _superseded(op)) return false;
      if (r == null) {
        tried.add('ws:ok create:timeout');
        await _closeWs();
        break;
      }
      if (r['type'] == 'error') {
        final c = (r['code'] ?? '').toString();
        tried.add('err:$c');
        await _closeWs();
        if (c == 'room_exists') continue;
        break;
      }
      // Created.
      _code = code;
      _myId = (r['user_id'] ?? _myId).toString();
      _sessionToken = (r['session_token'] ?? '').toString();
      if (_sessionToken!.isEmpty) _sessionToken = null;
      _roomName = name;
      _isHost = true;
      _joinedAt = _now();
      _phase = JamPhase.inRoom;
      _collab = const [];
      _collabLastSid = null;
      _enterRoomCommon();
      final st = r['state'];
      if (st is Map) _applyRoomState(Map<String, dynamic>.from(st));
      _seedTimelineFromEngine();
      // If something is already playing, start the room with it.
      _hostSyncNowPlaying();
      notifyListeners();
      return true;
    }
    debugInfo = tried.join(' | ');
    _fail(JamNotice.connectionFailed);
    return false;
  }

  /// Opens the room read-only so the UI can show "Rahul's Jam — Song name".
  Future<bool> peek(String rawCode) async {
    final code = parseCode(rawCode);
    if (code == null) {
      _fail(JamNotice.roomNotFound);
      return false;
    }
    if (_phase != JamPhase.idle) await leave(silent: true);
    await _loadPrefs();
    final op = ++_opSeq;
    _phase = JamPhase.connecting;
    _notice = JamNotice.none;
    notifyListeners();

    warmUp();
    Map<String, dynamic>? info;
    String? errCode;
    final tried = <String>[];
    for (var attempt = 0; attempt < 2 && info == null; attempt++) {
      final ok = await _connect(code, timeoutSec: attempt == 0 ? 15 : 10);
      if (await _superseded(op)) return false;
      if (!ok) {
        tried.add('ws:fail');
        await _closeWs();
        await Future.delayed(const Duration(milliseconds: 500));
        if (await _superseded(op)) return false;
        continue;
      }
      final r = await _request('peek_room', <String, dynamic>{}, {'room_info'}, timeoutMs: 8000);
      if (await _superseded(op)) return false;
      if (r == null) {
        tried.add('ws:ok info:timeout');
        await _closeWs();
        continue;
      }
      if (r['type'] == 'error') {
        errCode = (r['code'] ?? '').toString();
        tried.add('err:$errCode');
        break;
      }
      tried.add('ok');
      info = r;
    }
    debugInfo = tried.join(' | ');
    if (kDebugMode) debugPrint('[Jam] peek $code → $debugInfo');
    if (info == null) {
      await _closeWs();
      if (errCode == 'room_not_found') {
        _fail(JamNotice.roomNotFound);
      } else if (errCode == 'room_full') {
        _fail(JamNotice.roomFull);
      } else {
        _fail(JamNotice.connectionFailed);
      }
      return false;
    }
    final count = (info['count'] as num?)?.toInt() ?? 0;
    if (count >= maxMembers) {
      await _closeWs();
      _fail(JamNotice.roomFull);
      return false;
    }
    _code = code;
    previewRoomName = (info['room_name'] ?? '').toString();
    previewHostName = (info['host_name'] ?? '').toString();
    previewSong = (info['song'] ?? '').toString();
    previewHostAvatar = info['host_avatar']?.toString();
    previewAvatars = ((info['avatars'] as List?) ?? const []).map((e) => e?.toString()).toList();
    previewCount = count;
    _phase = JamPhase.previewing;
    notifyListeners();
    // Don't hold a socket open forever on the preview screen.
    _peekTimer?.cancel();
    _peekTimer = Timer(const Duration(seconds: 90), () {
      if (_phase == JamPhase.previewing) leave(silent: true);
    });
    return true;
  }

  /// Sends the join request to the host and waits for the answer.
  /// The host approves (or auto-approves) — see the "requesting" phase.
  Future<bool> join() async {
    if (_phase != JamPhase.previewing || _ws == null) return false;
    _peekTimer?.cancel();
    if (previewCount >= maxMembers) {
      await leave(silent: true);
      _fail(JamNotice.roomFull);
      return false;
    }
    final op = ++_opSeq;
    _phase = JamPhase.requesting;
    _notice = JamNotice.none;
    notifyListeners();

    final r = await _request(
      'join_room',
      {'room_code': _code, 'username': _myName, 'avatar': _myAvatar},
      {'join_approved', 'join_rejected'},
      timeoutMs: _approvalTimeoutMs,
    );
    if (await _superseded(op)) return false;

    if (r == null) {
      // The host never answered.
      await leave(silent: true);
      _notice = JamNotice.requestTimeout;
      notifyListeners();
      return false;
    }
    final type = (r['type'] ?? '').toString();
    if (type == 'join_rejected') {
      final reason = (r['reason'] ?? '').toString();
      await leave(silent: true);
      _notice = reason == 'full' ? JamNotice.roomFull : JamNotice.joinRejected;
      notifyListeners();
      return false;
    }
    if (type == 'error') {
      final c = (r['code'] ?? '').toString();
      await leave(silent: true);
      _notice = c == 'room_full'
          ? JamNotice.roomFull
          : (c == 'room_not_found' ? JamNotice.roomNotFound : JamNotice.connectionFailed);
      notifyListeners();
      return false;
    }
    if (type != 'join_approved') {
      await leave(silent: true);
      return false;
    }

    _isHost = false;
    _myId = (r['user_id'] ?? _myId).toString();
    _sessionToken = (r['session_token'] ?? '').toString();
    if (_sessionToken!.isEmpty) _sessionToken = null;
    _joinedAt = _now();
    _roomName = previewRoomName;
    _collab = const [];
    _collabLastSid = null;
    _phase = JamPhase.inRoom;
    _enterRoomCommon();
    final st = r['state'];
    if (st is Map) _applyRoomState(Map<String, dynamic>.from(st));
    _send({'t': 'hello'});
    notifyListeners();
    return true;
  }

  /// [endForAll] (host only): close the Jam for everybody. Without it a host
  /// who leaves hands the Jam to the longest-standing guest.
  Future<void> leave({bool silent = false, bool endForAll = false}) async {
    _opSeq++;
    final pendingReply = _reply;
    if (pendingReply != null && !pendingReply.isCompleted) {
      pendingReply.complete({'type': 'cancelled'});
    }
    final wasInRoom = _phase == JamPhase.inRoom;
    final wasGuest = wasInRoom && !_isHost;
    var sent = false;
    if (_phase == JamPhase.inRoom || _phase == JamPhase.requesting) {
      sent = _sendType(endForAll && _isHost ? 'end_room' : 'leave_room');
    }
    unawaited(_clearSession());
    _reconnectTimer?.cancel();
    _reconnecting = false;
    _reconnectAttempt = 0;
    _sessionToken = null;
    _stopTimers();
    // Guest leaves the room → its music stops RIGHT NOW (before any network work).
    if (wasGuest) unawaited(_stopOwnPlayback());

    // Flip the UI to idle FIRST. Closing the socket below is a network call
    // that can take seconds on a bad connection — the user must not sit on
    // the room screen (and tap Leave twice) while it finishes.
    _phase = JamPhase.idle;
    previewHostAvatar = null;
    previewAvatars = const [];
    _isHost = false;
    _members = const [];
    _pending = const [];
    _suggestions = const [];
    _collab = const [];
    _collabLastSid = null;
    _code = '';
    _roomName = '';
    _driftMs = 0;
    _driftSamples.clear();
    _inHold = false;
    _stalled.clear();
    _lastHoldAt.clear();
    _ready.clear();
    _guestRtt.clear();
    _lastQueueKey = '';
    _lastQueueMsg = null;
    _tl
      ..songId = null
      ..playing = false
      ..posMs = 0;
    if (!silent) _notice = JamNotice.none;
    notifyListeners();

    // Give the "leave" frame a moment to leave the phone before the socket closes.
    if (sent) await Future.delayed(const Duration(milliseconds: 250));
    await _closeWs();
    _stopConnectivityWatch();
    _jamBuffer(false);
    if (wasGuest) await _stopOwnPlayback(); // in case a load finished meanwhile
    try {
      await _engine.setJamHold(false);
    } catch (_) {}
    if (_curSpeed != 1.0) {
      _curSpeed = 1.0;
      try {
        await _engine.setSpeed(1.0);
      } catch (_) {}
    }
  }

  void _fail(JamNotice n) {
    previewHostAvatar = null;
    previewAvatars = const [];
    _phase = JamPhase.idle;
    _notice = n;
    notifyListeners();
  }

  /// The server removed us (kicked / Jam ended / seat expired) or the room
  /// is gone. Stops our music like a normal guest leave and tells the UI why.
  Future<void> _onRemoved(JamNotice why) async {
    if (_phase == JamPhase.idle) return;
    final wasGuest = !_isHost;
    await leave(silent: true);
    if (wasGuest) unawaited(_stopOwnPlayback());
    _notice = why;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════════
  // WebSocket plumbing
  // ══════════════════════════════════════════════════════════════════════
  Future<bool> _connect(String code, {int timeoutSec = 12}) async {
    await _closeWs();
    final gen = ++_wsGen;
    try {
      final uri = Uri.parse(_serverUrl).replace(queryParameters: {'room': code, 'v': '1'});
      final ws = await WebSocket.connect(uri.toString()).timeout(Duration(seconds: timeoutSec));
      if (gen != _wsGen) {
        try {
          await ws.close();
        } catch (_) {}
        return false;
      }
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      _wsOpen = true;
      _lastServerMsgAt = _now();
      ws.listen(
        (data) {
          if (gen == _wsGen) _onWsData(data);
        },
        onDone: () {
          if (gen == _wsGen) _onWsClosed();
        },
        onError: (Object e) {
          _log('socket error: $e');
          if (gen == _wsGen) _onWsClosed();
        },
        cancelOnError: true,
      );
      _log(hasCustomServer ? 'connected → ${uri.host}' : 'connected');
      return true;
    } catch (e) {
      _log('connect failed: $e');
      debugInfo = 'ws: ${e.toString().split('\n').first}';
      return false;
    }
  }

  Future<void> _closeWs() async {
    _wsGen++;
    _wsOpen = false;
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        await ws.close(1000, 'bye').timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  void _onWsData(dynamic data) {
    _lastServerMsgAt = _now();
    try {
      final text = data is String ? data : utf8.decode((data as List).cast<int>());
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final type = (decoded['type'] ?? '').toString();
      final payload = decoded['payload'] is Map
          ? Map<String, dynamic>.from(decoded['payload'] as Map)
          : <String, dynamic>{};
      _onServer(type, payload);
    } catch (e) {
      if (kDebugMode) debugPrint('[Jam] bad message: $e');
    }
  }

  void _onWsClosed() {
    _wsOpen = false;
    _ws = null;
    _log('socket closed (phase ${_phase.name})');
    if (_phase == JamPhase.inRoom) {
      if (_sessionToken != null) {
        _beginReconnect();
      } else {
        unawaited(_onRemoved(JamNotice.connectionFailed));
      }
      return;
    }
    // Connecting / requesting: wake the awaiting call with an error.
    final r = _reply;
    if (r != null && !r.isCompleted) {
      r.complete({'type': 'error', 'code': 'closed'});
      return;
    }
    if (_phase == JamPhase.previewing) {
      unawaited(leave(silent: true));
      _notice = JamNotice.connectionFailed;
      notifyListeners();
    }
  }

  bool _sendType(String type, [Map<String, dynamic>? payload]) {
    final ws = _ws;
    if (ws == null || !_wsOpen) return false;
    try {
      ws.add(jsonEncode({'type': type, if (payload != null) 'payload': payload}));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends one request and waits for the first matching reply (or `error`).
  /// Returns null on timeout / not connected.
  Future<Map<String, dynamic>?> _request(
    String type,
    Map<String, dynamic>? payload,
    Set<String> replyTypes, {
    int timeoutMs = 10000,
  }) async {
    final c = Completer<Map<String, dynamic>>();
    _reply = c;
    _replyTypes = replyTypes;
    if (!_sendType(type, payload)) {
      if (identical(_reply, c)) _reply = null;
      return null;
    }
    try {
      return await c.future.timeout(Duration(milliseconds: timeoutMs));
    } on TimeoutException {
      return null;
    } finally {
      if (identical(_reply, c)) _reply = null;
    }
  }

  /// Sync traffic between phones. The server only relays it: [m] may carry
  /// 'to' (a member id) to address one phone; otherwise everybody else gets it.
  void _send(Map<String, dynamic> m) {
    final data = Map<String, dynamic>.of(m);
    final to = data.remove('to')?.toString();
    _sendType('relay', {if (to != null) 'to': to, 'data': data});
  }

  /// A pause is the one message that must never be lost. Send it again
  /// shortly after (only while still paused); guests treat repeats as no-ops.
  void _sendBurst(Map<String, dynamic> m) {
    _send(m);
    for (final ms in const [350, 1100]) {
      Timer(Duration(milliseconds: ms), () {
        if (_isHost && _phase == JamPhase.inRoom && !_tl.playing) _send(Map<String, dynamic>.of(m));
      });
    }
  }

  /// Tells the server how we are doing (member list, join preview).
  Future<bool> _track() async {
    if (_phase != JamPhase.inRoom) return false;
    return _sendType('status', {
      'status': _myStatus,
      if (_isHost) 'song': _currentSongLabel(),
    });
  }

  String _currentSongLabel() {
    final s = _player?.currentSong;
    if (s == null) return '';
    return '${s.title} • ${s.artist}';
  }

  // ── Reconnect (socket dropped while in a room) ────────────────────────────
  void _beginReconnect() {
    if (_reconnecting || _phase != JamPhase.inRoom) return;
    _reconnecting = true;
    _reconnectAttempt = 0;
    _disconnectedAt = _now();
    _notice = JamNotice.reconnecting;
    _log('reconnecting…');
    notifyListeners();
    _scheduleReconnect(300);
  }

  void _scheduleReconnect(int delayMs) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () => unawaited(_tryReconnect()));
  }

  Future<void> _tryReconnect() async {
    if (_phase != JamPhase.inRoom || !_reconnecting) return;
    if (_now() - _disconnectedAt > _sessionGraceMs) {
      await _onRemoved(JamNotice.sessionExpired);
      return;
    }
    final token = _sessionToken;
    if (token == null) {
      await _onRemoved(JamNotice.sessionExpired);
      return;
    }
    _reconnectAttempt++;
    final ok = await _connect(_code, timeoutSec: 10);
    if (_phase != JamPhase.inRoom || !_reconnecting) {
      if (ok) await _closeWs();
      return;
    }
    if (ok) {
      final r = await _request('reconnect', {'session_token': token}, {'reconnected'}, timeoutMs: 8000);
      if (_phase != JamPhase.inRoom || !_reconnecting) return;
      if (r != null && r['type'] == 'reconnected') {
        _onReconnected(r);
        return;
      }
      if (r != null && r['type'] == 'error' && (r['code'] ?? '') != 'closed') {
        // The server no longer knows this seat.
        await _onRemoved(JamNotice.sessionExpired);
        return;
      }
      await _closeWs();
    }
    final backoff = min(15000, 1000 * (1 << min(_reconnectAttempt, 4)));
    _scheduleReconnect(backoff + Random().nextInt(600));
  }

  void _onReconnected(Map<String, dynamic> r) {
    _reconnecting = false;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _lastServerMsgAt = _now();
    _myId = (r['user_id'] ?? _myId).toString();
    if (_notice == JamNotice.reconnecting) _notice = JamNotice.none;
    final st = r['state'];
    if (st is Map) _applyRoomState(Map<String, dynamic>.from(st));
    final host = r['is_host'] == true;
    if (host && !_isHost) {
      _promoteToHost();
    } else if (!host && _isHost) {
      _demoteToGuest();
    }
    _startClockSync();
    unawaited(_saveSession());
    _track();
    if (_isHost) {
      _seedTimelineFromEngine();
      _hostHeartbeat();
    } else {
      _graceUntil = _now() + 3000;
      _send({'t': 'hello'});
    }
    _log('reconnected');
    notifyListeners();
  }

  void _startConnectivityWatch() {
    _connSub ??= Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _reconnecting && _phase == JamPhase.inRoom) {
        _scheduleReconnect(200); // network is back → don't wait for the backoff
      }
    }, onError: (_) {});
  }

  void _stopConnectivityWatch() {
    _connSub?.cancel();
    _connSub = null;
  }

  /// No frame from the server for 35 s although we think we're connected →
  /// the socket silently died (WiFi↔mobile switch, hotspot nap). We ping every
  /// 12 s, so a healthy socket is never this quiet.
  void _livenessCheck() {
    if (_reconnecting || _phase != JamPhase.inRoom) return;
    if (_now() - _lastServerMsgAt > 35000) {
      _log('server silent → reconnect');
      unawaited(_closeWs());
      _beginReconnect();
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // Server messages
  // ══════════════════════════════════════════════════════════════════════
  void _onServer(String type, Map<String, dynamic> p) {
    final c = _reply;
    if (c != null && !c.isCompleted && (type == 'error' || _replyTypes.contains(type))) {
      c.complete({'type': type, ...p});
      return;
    }
    switch (type) {
      case 'pong':
        _onServerPong(p);
        break;
      case 'relay':
        _onRelay(p);
        break;
      case 'room_state':
        if (_phase == JamPhase.inRoom) _applyRoomState(p);
        break;
      case 'join_request':
        _onJoinRequest(p);
        break;
      case 'join_request_cancelled':
        final id = (p['user_id'] ?? '').toString();
        final before = _pending.length;
        _pending = _pending.where((r) => r.userId != id).toList();
        if (_pending.length != before) notifyListeners();
        break;
      case 'host_changed':
        _onHostChanged(p);
        break;
      case 'kicked':
        unawaited(_onRemoved(JamNotice.kicked));
        break;
      case 'room_ended':
        unawaited(_onRemoved(JamNotice.hostEnded));
        break;
      case 'suggestion_received':
        _onSuggestionReceived(p);
        break;
      case 'suggestion_approved':
        _notice = JamNotice.suggestionApproved;
        notifyListeners();
        break;
      case 'suggestion_rejected':
        _notice = JamNotice.suggestionRejected;
        notifyListeners();
        break;
      case 'error':
        final code = (p['code'] ?? '').toString();
        _log('server error: $code ${p['message'] ?? ''}');
        if ((code == 'session_not_found' || code == 'room_not_found') && _phase == JamPhase.inRoom) {
          unawaited(_onRemoved(JamNotice.sessionExpired));
        }
        break;
    }
  }

  void _onRelay(Map<String, dynamic> p) {
    if (_phase != JamPhase.inRoom) return;
    final d = p['data'];
    if (d is! Map) return;
    final m = Map<String, dynamic>.from(d);
    m['f'] = (p['from'] ?? '').toString();
    _onMessage(m);
  }

  /// The server's member list is the single truth (who is in, who is host,
  /// who is connected). Role changes are reconciled from it.
  void _applyRoomState(Map<String, dynamic> s) {
    final raw = (s['users'] as List?) ?? const [];
    final list = raw.map((e) {
      final u = Map<String, dynamic>.from(e as Map);
      return JamMember(
        id: (u['user_id'] ?? '').toString(),
        name: (u['username'] ?? 'Guest').toString(),
        avatar: u['avatar']?.toString(),
        isHost: u['is_host'] == true,
        joinedAt: ((u['joined_at'] ?? 0) as num).toInt(),
        status: (u['status'] ?? 'ok').toString(),
        connected: u['is_connected'] != false,
      );
    }).toList()
      ..sort((a, b) {
        if (a.isHost != b.isHost) return a.isHost ? -1 : 1;
        return a.joinedAt.compareTo(b.joinedAt);
      });

    final oldIds = _members.map((m) => m.id).toSet();
    final newIds = list.map((m) => m.id).toSet();
    final removed = oldIds.difference(newIds);
    for (final id in removed) {
      _stalled.remove(id);
      _guestRtt.remove(id);
      _lastHoldAt.remove(id);
    }
    _members = list;

    final rn = (s['room_name'] ?? '').toString();
    if (rn.isNotEmpty) _roomName = rn;

    final hid = (s['host_id'] ?? '').toString();
    if (hid.isNotEmpty && _phase == JamPhase.inRoom) {
      if (hid == _myId && !_isHost) {
        _promoteToHost();
      } else if (hid != _myId && _isHost) {
        _demoteToGuest();
      }
    }
    if (removed.isNotEmpty || list.any((m) => !m.connected)) _wakeBarrier();
    notifyListeners();
  }

  void _onHostChanged(Map<String, dynamic> p) {
    final id = (p['new_host_id'] ?? '').toString();
    if (id.isEmpty || _phase != JamPhase.inRoom) return;
    if (id == _myId && !_isHost) {
      _promoteToHost();
    } else if (id != _myId && _isHost) {
      _demoteToGuest();
    }
  }

  void _promoteToHost() {
    _isHost = true;
    _notice = JamNotice.youAreHostNow;
    _seedTimelineFromEngine();
    _track();
    _startRoomTimers();
    unawaited(_saveSession());
    notifyListeners();
  }

  void _demoteToGuest() {
    _isHost = false;
    _hbTimer?.cancel();
    _holdTimer?.cancel();
    _inHold = false;
    _pending = const [];
    _suggestions = const [];
    _track();
    _send({'t': 'hello'});
    unawaited(_saveSession());
    notifyListeners();
  }

  // ── Join requests (host) ─────────────────────────────────────────────────
  List<JamJoinRequest> _pending = const [];
  List<JamJoinRequest> get pendingRequests => _pending;

  void _onJoinRequest(Map<String, dynamic> p) {
    if (!_isHost || _phase != JamPhase.inRoom) return;
    final id = (p['user_id'] ?? '').toString();
    final name = (p['username'] ?? 'Guest').toString();
    if (id.isEmpty) return;
    if (isBlocked(name)) {
      _sendType('reject_join', {'user_id': id, 'reason': 'blocked'});
      return;
    }
    if (_members.where((m) => m.connected).length >= maxMembers) {
      _sendType('reject_join', {'user_id': id, 'reason': 'full'});
      return;
    }
    if (_pending.any((r) => r.userId == id)) return;
    if (_autoApprove) {
      _sendType('approve_join', {'user_id': id});
      return;
    }
    _pending = [..._pending, JamJoinRequest(userId: id, username: name, avatar: p['avatar']?.toString(), at: _now())];
    _notice = JamNotice.joinRequest;
    notifyListeners();
    if (_inBackground) unawaited(NotificationService.instance.showJamRequest(name));
  }

  void approveJoin(String userId) {
    if (!_isHost) return;
    _sendType('approve_join', {'user_id': userId});
    _pending = _pending.where((r) => r.userId != userId).toList();
    notifyListeners();
  }

  void rejectJoin(String userId) {
    if (!_isHost) return;
    _sendType('reject_join', {'user_id': userId, 'reason': 'rejected'});
    _pending = _pending.where((r) => r.userId != userId).toList();
    notifyListeners();
  }

  // ── Members (host) ───────────────────────────────────────────────────────
  void kickUser(String userId) {
    if (!_isHost || userId == _myId) return;
    _sendType('kick_user', {'user_id': userId, 'reason': 'kicked'});
  }

  void transferHost(String userId) {
    if (!_isHost || userId == _myId) return;
    _sendType('transfer_host', {'new_host_id': userId});
  }

  // ── Song suggestions ─────────────────────────────────────────────────────
  List<JamSuggestion> _suggestions = const [];
  List<JamSuggestion> get suggestions => _suggestions;

  /// Guest → host: "play this next?". Returns false when not possible.
  bool suggestSong(Song song) {
    if (_phase != JamPhase.inRoom || _isHost) return false;
    if (song.isLocal) {
      _notice = JamNotice.localSongSkipped;
      notifyListeners();
      return false;
    }
    final ok = _sendType('suggest_track', {'track': _songForWire(song)});
    if (ok) {
      _notice = JamNotice.suggestionSent;
      notifyListeners();
    }
    return ok;
  }

  void _onSuggestionReceived(Map<String, dynamic> p) {
    if (!_isHost || _phase != JamPhase.inRoom) return;
    final from = (p['from_username'] ?? 'Guest').toString();
    if (isBlocked(from)) return;
    final t = p['track'];
    if (t is! Map) return;
    final id = (p['suggestion_id'] ?? '').toString();
    if (id.isEmpty || _suggestions.any((s) => s.id == id)) return;
    final song = _songFromWire(Map<String, dynamic>.from(t));
    _suggestions = [
      ..._suggestions,
      JamSuggestion(id: id, fromUserId: (p['from_user_id'] ?? '').toString(), fromUsername: from, song: song),
    ];
    _notice = JamNotice.suggestionIncoming;
    notifyListeners();
    if (_inBackground) unawaited(NotificationService.instance.showJamSuggestion(from, song.title));
  }

  Future<void> approveSuggestion(String id) async {
    if (!_isHost) return;
    final i = _suggestions.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final s = _suggestions[i];
    _suggestions = [..._suggestions]..removeAt(i);
    _sendType('approve_suggestion', {'suggestion_id': id});
    notifyListeners();
    final p = _player;
    if (p == null) return;
    try {
      if (p.currentSong == null) {
        await p.playSong(s.song, queue: [s.song], index: 0);
      } else {
        // The queue observer sends the new "up next" to everybody.
        await p.playNext(s.song);
      }
    } catch (_) {}
  }

  void rejectSuggestion(String id) {
    if (!_isHost) return;
    _suggestions = _suggestions.where((s) => s.id != id).toList();
    _sendType('reject_suggestion', {'suggestion_id': id});
    notifyListeners();
  }

  // ── Collaborative playlist: every song that plays in the room ────────────
  List<Song> _collab = const [];
  List<Song> get collabTracks => _collab;
  String? _collabLastSid;

  void _collabTrack(NativeEngineState s) {
    final sid = s.currentSongId;
    if (sid == null || sid == _collabLastSid) return;
    final song = _player?.currentSong;
    if (song == null || song.id != sid || song.isLocal) return;
    _collabLastSid = sid;
    if (_collab.any((x) => x.id == sid)) return;
    _collab = [..._collab, song];
    notifyListeners();
  }

  void removeFromCollab(String songId) {
    _collab = _collab.where((s) => s.id != songId).toList();
    notifyListeners();
  }

  /// Saves the session playlist into the user's library. Returns the number
  /// of songs saved.
  Future<int> saveCollabAsPlaylist(PlaylistProvider playlists, {String? name}) async {
    if (_collab.isEmpty) return 0;
    final label = (name ?? '').trim().isNotEmpty
        ? name!.trim()
        : (_roomName.isEmpty ? 'Jam playlist' : '$_roomName • Jam');
    final pl = await playlists.createPlaylist(name: label);
    var n = 0;
    for (final s in _collab) {
      if (await playlists.addSong(pl.id, s)) n++;
    }
    return n;
  }

  // ── Host → guests: live "up next" ────────────────────────────────────────
  void _maybeSyncQueue(NativeEngineState s) {
    final idx = s.currentIndex ?? -1;
    final upcoming = (idx >= 0 && idx < s.queueIds.length) ? s.queueIds.sublist(idx + 1) : const <String>[];
    final key = '${s.currentSongId}:${upcoming.join(',')}';
    if (key == _lastQueueKey) return;
    _lastQueueKey = key;
    if (_alone || _loading || _inHold) return;
    _queueTimer?.cancel();
    _queueTimer = Timer(const Duration(milliseconds: 700), _sendQueueSync);
  }

  void _sendQueueSync() {
    if (!_isHost || _phase != JamPhase.inRoom || _alone) return;
    final p = _player;
    final cur = _es.currentSongId;
    if (p == null || cur == null) return;
    final q = p.queue;
    final idx = q.indexWhere((s) => s.id == cur);
    if (idx < 0) return;
    final up = <Song>[];
    for (var i = idx + 1; i < q.length && up.length < _maxQueueSent; i++) {
      if (!q[i].isLocal) up.add(q[i]);
    }
    _send({'t': 'queue', 'sid': cur, 'songs': up.map(_songForWire).toList()});
  }

  void _onQueueMsg(Map<String, dynamic> m) {
    _lastQueueMsg = m;
    unawaited(_applyQueueMsg());
    // If we are a beat behind on the song, look again shortly.
    _queueRetry?.cancel();
    _queueRetry = Timer(const Duration(milliseconds: 1800), () => unawaited(_applyQueueMsg()));
  }

  Future<void> _applyQueueMsg() async {
    final m = _lastQueueMsg;
    final p = _player;
    if (m == null || p == null || _queueApplying || _loading || _isHost || _phase != JamPhase.inRoom) return;
    final sid = m['sid']?.toString();
    if (sid == null || _es.currentSongId != sid) return;
    final want = ((m['songs'] as List?) ?? const [])
        .map((e) => _songFromWire(Map<String, dynamic>.from(e as Map)))
        .toList();
    final q = p.queue;
    final idx = q.indexWhere((s) => s.id == sid);
    if (idx < 0) return;
    final have = q.sublist(idx + 1).map((s) => s.id).toList();
    final wantIds = want.map((s) => s.id).toList();
    if (listEquals(have, wantIds)) {
      _lastQueueMsg = null;
      return;
    }
    _queueApplying = true;
    try {
      for (var i = q.length - 1; i > idx; i--) {
        await p.removeFromQueue(i);
      }
      if (want.isNotEmpty) await p.addSongsToQueue(want);
      _lastQueueMsg = null;
    } catch (_) {
    } finally {
      _queueApplying = false;
    }
  }

  // ── Small helpers ────────────────────────────────────────────────────────
  bool get _inBackground {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s != null && s != AppLifecycleState.resumed;
    } catch (_) {
      return false;
    }
  }

  final List<String> _logLines = [];
  List<String> get logs => List.unmodifiable(_logLines);
  void clearLogs() {
    _logLines.clear();
    notifyListeners();
  }

  void _log(String msg) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    _logLines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $msg');
    if (_logLines.length > 200) _logLines.removeRange(0, _logLines.length - 200);
    if (kDebugMode) debugPrint('[Jam] $msg');
  }

  // ══════════════════════════════════════════════════════════════════════
  // Timers
  // ══════════════════════════════════════════════════════════════════════
  void _startRoomTimers() {
    _hbTimer?.cancel();
    _driftTimer?.cancel();
    if (_isHost) {
      _hbTimer = Timer.periodic(const Duration(seconds: 5), (_) => _hostHeartbeat());
    }
    _driftTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _tick());
  }

  void _stopTimers() {
    _hbTimer?.cancel();
    _driftTimer?.cancel();
    _pingTimer?.cancel();
    _goTimer?.cancel();
    _holdTimer?.cancel();
    _peekTimer?.cancel();
    _busyRecheck?.cancel();
    _queueTimer?.cancel();
    _queueRetry?.cancel();
    _trackTimer?.cancel();
    _trackTimer = null;
    _hbTimer = _busyRecheck = _driftTimer = _pingTimer = _goTimer = _holdTimer = _peekTimer = null;
    _queueTimer = _queueRetry = null;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Clock sync (guest)
  // ══════════════════════════════════════════════════════════════════════
  void _startClockSync() {
    _clockSamples.clear();
    _pingsLeftInBurst = 6;
    _pingTimer?.cancel();
    _sendType('ping', {'t0': _now()});
    _pingTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (_phase != JamPhase.inRoom) {
        t.cancel();
        return;
      }
      _sendType('ping', {'t0': _now()});
      if (--_pingsLeftInBurst <= 0) {
        t.cancel();
        // After the burst, one refresh every 12 s keeps the offset fresh
        // (and proves the socket is alive).
        _pingTimer = Timer.periodic(const Duration(seconds: 12), (t2) {
          if (_phase != JamPhase.inRoom) {
            t2.cancel();
            return;
          }
          _sendType('ping', {'t0': _now()});
        });
      }
    });
  }

  /// Server answered our ping: {t0: our send time, ts: server clock}.
  void _onServerPong(Map<String, dynamic> m) {
    final t0 = (m['t0'] as num?)?.toInt();
    final ts = (m['ts'] as num?)?.toInt();
    if (t0 == null || ts == null) return;
    final t1 = _now();
    final rtt = t1 - t0;
    if (rtt < 0 || rtt > 3000) return;
    final offset = ts - (t0 + rtt ~/ 2);
    _clockSamples.add([rtt, offset]);
    if (_clockSamples.length > 12) _clockSamples.removeAt(0);
    final sorted = [..._clockSamples]..sort((a, b) => a[0].compareTo(b[0]));
    final best = sorted.take(3).toList();
    _offsetMs = (best.fold<int>(0, (sum, e) => sum + e[1]) / best.length).round();
  }

  // ══════════════════════════════════════════════════════════════════════
  // Message router
  // ══════════════════════════════════════════════════════════════════════
  /// Sync messages relayed by the server from another member (m['f'] = sender).
  void _onMessage(Map<String, dynamic> m) {
    final from = (m['f'] ?? '').toString();
    final type = (m['t'] ?? '').toString();
    if (_phase != JamPhase.inRoom) return;

    switch (type) {
      // ── host-bound ──
      case 'hello':
        if (_isHost) _sendStateTo(from);
        break;
      case 'ready':
        if (_isHost) _onReady(from, (m['lid'] as num?)?.toInt() ?? 0, m['stall'] == true, (m['rtt'] as num?)?.toInt() ?? 0);
        break;
      case 'wait':
        if (_isHost) _onWait(from);
        break;

      // ── guest-bound ──
      case 'state':
        if (!_isHost) _onState(m);
        break;
      case 'load':
        if (!_isHost) _onLoad(m);
        break;
      case 'go':
        if (!_isHost) _onGo(m);
        break;
      case 'pause':
        if (!_isHost) _onPauseMsg(m);
        break;
      case 'track':
        if (!_isHost) _onTrack(m);
        break;
      case 'hb':
        if (!_isHost) _onHeartbeat(m);
        break;
      case 'queue':
        if (!_isHost) _onQueueMsg(m);
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // Engine mirror
  // ══════════════════════════════════════════════════════════════════════
  void _onEngineState(NativeEngineState s) {
    final prev = _es;
    _prevSongId = prev.currentSongId;
    _prevPosMs = _estimatedPosMs();
    _es = s;
    _esAtLocal = _now();
    _prevDurMs = _lastDurMs;
    final d = s.duration;
    if (d != null && d.inMilliseconds > 0) _lastDurMs = d.inMilliseconds;
    if (_phase != JamPhase.inRoom) return;

    _collabTrack(s);
    if (_isHost) _maybeSyncQueue(s);

    // My own status for the member list (only publish on change).
    final st = (s.processingState == 'buffering' || s.processingState == 'loading') ? 'buffering' : 'ok';
    if (st != _myStatus && !_loading) {
      _myStatus = st;
      _trackSoon(); // coalesced: slow nets flip buffering↔ok often
      notifyListeners();
    }

    if (_isHost) {
      _hostWatch(prev, s);
    } else {
      _guestWatch(s);
    }
  }

  /// Best guess of the engine's position right now (ms).
  int _estimatedPosMs() {
    final s = _es;
    final base = s.position.inMilliseconds;
    if (!s.playing || s.processingState != 'ready') return base;
    final dt = _now() - _esAtLocal;
    if (dt < 0 || dt > 2500) return base;
    return base + (dt * s.speed).round();
  }

  Future<void> _waitUntilReady({required int minBufferedMs, int timeoutMs = 10000}) async {
    final end = _now() + timeoutMs;
    while (_now() < end && _phase == JamPhase.inRoom) {
      final s = _es;
      final ready = s.processingState == 'ready';
      final buf = s.bufferedPosition.inMilliseconds;
      final dur = s.duration?.inMilliseconds ?? 0;
      // "Ready" AND a little audio buffered ahead (or the whole song).
      if (ready && (buf >= minBufferedMs || (dur > 0 && buf >= dur - 500))) return;
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // HOST
  // ══════════════════════════════════════════════════════════════════════
  void _seedTimelineFromEngine() {
    _tl
      ..songId = _es.currentSongId
      ..posMs = _estimatedPosMs()
      ..atHost = _hostNow
      ..playing = _es.playing;
  }

  void _hostSyncNowPlaying() {
    final s = _player?.currentSong;
    if (s == null || s.isLocal) return;
    // Something already playing: put everyone (just the host for now) on the
    // barrier path so late joiners find a consistent timeline.
    _seedTimelineFromEngine();
  }

  bool get _alone => !_members.any((m) => m.id != _myId && m.connected);

  int _hostPosNow() {
    if (!_tl.playing) return _tl.posMs;
    return _tl.posMs + (_hostNow - _tl.atHost);
  }

  void _hostHeartbeat() {
    if (!_isHost || _phase != JamPhase.inRoom) return;
    // Safety net: the host's player is paused but the room still thinks it
    // plays (a pause event we missed) → pause everyone now.
    if (!_alone && _tl.playing && !_es.playing && _es.processingState == 'ready' &&
        !_loading && !_inHold && _now() > _busyUntil) {
      hostPause();
    }
    // Refresh timeline from the host's real engine so guests follow reality.
    if (_es.playing && _es.processingState == 'ready' && !_loading && !_inHold && _now() > _busyUntil) {
      _tl
        ..songId = _es.currentSongId
        ..posMs = _estimatedPosMs() - _nudgeMs
        ..atHost = _hostNow
        ..playing = true;
    }
    _send({
      't': 'hb',
      'sid': _tl.songId,
      'pos': _tl.posMs,
      'at': _tl.atHost,
      'pl': _tl.playing,
    });
    _track(); // keeps "now playing" on the preview card fresh
  }

  List<Map<String, dynamic>> _queueWindow(Song current, List<Song> queue, int idx, void Function(int) setIdx) {
    final online = <Song>[];
    var newIdx = 0;
    final start = max(0, idx - 3);
    final end = min(queue.length, start + _maxQueueSent);
    for (var i = start; i < end; i++) {
      final s = queue[i];
      if (s.isLocal) continue;
      if (i == idx) newIdx = online.length;
      online.add(s);
    }
    if (online.isEmpty) online.add(current);
    setIdx(newIdx);
    return online.map(_songForWire).toList();
  }

  Map<String, dynamic> _songForWire(Song s) => {
        'id': s.id,
        'title': s.title,
        'artist': s.artist,
        'album': s.album,
        'artworkUrl': s.artworkUrl,
        'duration': s.duration,
        'language': s.language,
        'year': s.year,
        'source': s.source.name,
        'artistChannelId': s.artistChannelId,
      };

  Song _songFromWire(Map<String, dynamic> j) => Song.fromJson(j);

  /// Host picks / skips / starts a song → everybody loads it paused,
  /// buffers, and starts together.
  Future<void> hostLoad({
    required Song song,
    required List<Song> queue,
    required int index,
    int startPosMs = 0,
  }) async {
    if (!_isHost || _phase != JamPhase.inRoom) return;
    if (song.isLocal) {
      _notice = JamNotice.localSongSkipped;
      notifyListeners();
      return;
    }
    final lid = ++_lid;
    _ready[lid] = <String>{};
    _tl.playing = false;
    _inHold = false;
    _holdTimer?.cancel();
    _stalled.clear();
    _busyUntil = _now() + _barrierTimeoutMs + 3000;

    var wireIdx = 0;
    final wire = _queueWindow(song, queue, index, (i) => wireIdx = i);
    _send({'t': 'load', 'lid': lid, 'songs': wire, 'idx': wireIdx, 'sid': song.id, 'pos': startPosMs});
    final songs = wire.map(_songFromWire).toList();
    await _applyLoad(songs, wireIdx, startPosMs);
    if (_phase != JamPhase.inRoom || lid != _lid) return;
    _ready[lid]?.add(_myId);

    // Wait until every guest is ready, or give up after the timeout.
    final end = _now() + _barrierTimeoutMs;
    while (_now() < end && _phase == JamPhase.inRoom && lid == _lid) {
      final guests = _members.where((m) => m.id != _myId && m.connected).map((m) => m.id).toSet();
      if (guests.every((g) => _ready[lid]?.contains(g) ?? false)) break;
      _barrierWake = Completer<void>();
      await Future.any([
        _barrierWake!.future,
        Future.delayed(const Duration(milliseconds: 400)),
      ]);
    }
    if (_phase != JamPhase.inRoom || lid != _lid) return;
    _hostGo(startPosMs, lid: lid);
  }

  int _goneLid = -1; // last load id whose "go" was already sent

  void _onReady(String from, int lid, bool stall, [int rtt = 0]) {
    if (rtt > 0) _guestRtt[from] = rtt;
    if (stall) {
      // A guest recovered from a stall.
      _stalled.remove(from);
      if (_inHold && _stalled.isEmpty) _hostResumeFromHold();
      return;
    }
    _ready[lid]?.add(from);
    _wakeBarrier();
    // Late joiner / re-syncing guest (lid 0), or a guest that missed the
    // barrier (its load finished after "go" was sent): give THEM a personal
    // go-signal on the current timeline. While the barrier is still open
    // the broadcast "go" covers everyone, so nothing is sent here.
    final missedBarrier = lid == 0 || lid == _goneLid;
    if (missedBarrier && _tl.playing && !_loading && !_inHold) {
      final at = _hostNow + _goDelayMs;
      final pos = _hostPosNow() + _goDelayMs;
      _send({'t': 'go', 'to': from, 'pos': pos, 'at': at, 'lid': lid, 'sid': _tl.songId});
    }
  }

  void _hostGo(int posMs, {int lid = 0}) {
    // Alone in the room → nobody to wait for, start almost instantly.
    final at = _hostNow + _goDelayMs;
    _tl
      ..songId = _es.currentSongId ?? _tl.songId
      ..posMs = posMs
      ..atHost = at
      ..playing = true;
    _busyUntil = at + 1500;
    _goneLid = lid;
    _send({'t': 'go', 'pos': posMs, 'at': at, 'lid': lid, 'sid': _tl.songId});
    _scheduleStart(posMs, at);
  }

  Future<void> hostPause() async {
    if (!_isHost || _phase != JamPhase.inRoom) return;
    final pos = _hostPosNow().clamp(0, 1 << 30).toInt();
    _tl
      ..posMs = pos
      ..atHost = _hostNow
      ..playing = false;
    _busyUntil = _now() + 1500;
    _goTimer?.cancel();
    _sendBurst({'t': 'pause', 'pos': pos});
    try {
      await _engine.pause();
      await _engine.seek(Duration(milliseconds: pos));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> hostResume() async {
    if (!_isHost || _phase != JamPhase.inRoom) return;
    _hostGo(_tl.posMs);
    notifyListeners();
  }

  Future<void> hostSeek(Duration pos) async {
    if (!_isHost || _phase != JamPhase.inRoom) return;
    _hostGo(pos.inMilliseconds);
  }

  // Natural end-of-song: everyone's engine moves on by itself (gapless), the
  // host only tells guests which song to expect.
  void _hostAnnounceTrack(String songId) {
    final now = _hostNow;
    _tl
      ..songId = songId
      ..posMs = 0
      ..atHost = now
      ..playing = true;
    final idx = _es.currentIndex ?? 0;
    _send({'t': 'track', 'sid': songId, 'idx': idx, 'at': now});
  }

  void _onWait(String from) {
    if (_inHold || !_tl.playing) return;
    // One guest with a bad connection must not stop the music for everyone
    // again and again: it gets one room-wide pause per 20 s, after that it
    // catches up on its own (drift correction / seek).
    final now = _now();
    if (now - (_lastHoldAt[from] ?? 0) < 20000) return;
    _lastHoldAt[from] = now;
    _inHold = true;
    _stalled.add(from);
    _notice = JamNotice.waitingForFriend;
    final pos = _hostPosNow();
    _tl
      ..posMs = pos
      ..atHost = _hostNow
      ..playing = false;
    _busyUntil = _now() + _stallHoldMs + 2500;
    _send({'t': 'pause', 'pos': pos, 'hold': true});
    _engine.pause();
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: _stallHoldMs), _hostResumeFromHold);
    notifyListeners();
  }

  void _hostResumeFromHold() {
    if (!_inHold) return;
    _inHold = false;
    _holdTimer?.cancel();
    _stalled.clear();
    if (_notice == JamNotice.waitingForFriend) _notice = JamNotice.none;
    _hostGo(_tl.posMs);
    notifyListeners();
  }

  void _sendStateTo(String guestId) {
    final p = _player;
    final cur = p?.currentSong;
    if (p == null || cur == null || cur.isLocal) {
      _send({'t': 'state', 'to': guestId, 'room': _roomName, 'songs': [], 'sid': null, 'pl': false});
      return;
    }
    final q = p.queue;
    var idx = q.indexWhere((s) => s.id == cur.id);
    if (idx < 0) idx = 0;
    var wireIdx = 0;
    final wire = _queueWindow(cur, q.isEmpty ? [cur] : q, idx, (i) => wireIdx = i);
    _send({
      't': 'state',
      'to': guestId,
      'room': _roomName,
      'songs': wire,
      'idx': wireIdx,
      'sid': cur.id,
      'pl': _tl.playing,
      'pos': _hostPosNow(),
      'at': _hostNow,
    });
  }

  /// Host watches its own engine so that using the normal mini player /
  /// full player / notification also drives the room.
  void _recheckAfterBusy() {
    _busyRecheck?.cancel();
    final wait = _busyUntil - _now() + 200;
    _busyRecheck = Timer(Duration(milliseconds: wait < 200 ? 200 : wait), () {
      if (_isHost && _phase == JamPhase.inRoom) _hostWatch(_es, _es);
    });
  }

  void _hostWatch(NativeEngineState prev, NativeEngineState s) {
    if (_loading) return;
    if (_now() < _busyUntil) {
      _recheckAfterBusy(); // don't lose a pause/skip made right after a start
      return;
    }
    final sid = s.currentSongId;

    // Nobody else in the room: the host's own player is the truth. No
    // barrier, no pause, no delay — a solo host feels completely normal, and
    // a friend who joins later gets the live timeline via the "state" reply.
    if (_alone) {
      final toggled = s.playing != _tl.playing;
      _tl
        ..songId = sid ?? _tl.songId
        ..posMs = s.position.inMilliseconds
        ..atHost = _hostNow
        ..playing = s.playing;
      if (toggled) _hostHeartbeat(); // a guest the presence list hasn't shown yet still hears it
      return;
    }

    // Song changed
    if (sid != null && sid != _tl.songId) {
      final wasNearEnd = _prevDurMs > 0 && (_prevDurMs - _prevPosMs) < 2800;
      if (wasNearEnd && _tl.playing) {
        _hostAnnounceTrack(sid);
      } else {
        // Manual skip/pick: hold the host right away, then run the barrier.
        _engine.pause();
        final p = _player;
        final cur = p?.currentSong;
        if (p != null && cur != null) {
          var idx = p.queue.indexWhere((x) => x.id == cur.id);
          if (idx < 0) idx = 0;
          hostLoad(song: cur, queue: p.queue.isEmpty ? [cur] : p.queue, index: idx);
        }
      }
      return;
    }

    // Play / pause toggled by the host outside the Jam page
    if (s.playing != _tl.playing && s.processingState == 'ready' && !_inHold) {
      if (s.playing) {
        _engine.pause();
        hostResume();
      } else {
        hostPause();
      }
      return;
    }

    // Big seek (dragged the bar)
    if (s.playing && _tl.playing) {
      final jump = (s.position.inMilliseconds - _hostPosNow()).abs();
      if (jump > 2500) {
        _engine.pause();
        hostSeek(s.position);
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // GUEST
  // ══════════════════════════════════════════════════════════════════════
  void _onState(Map<String, dynamic> m) {
    final room = (m['room'] ?? '').toString();
    if (room.isNotEmpty) _roomName = room;
    final songsRaw = (m['songs'] as List?) ?? const [];
    final sid = m['sid']?.toString();
    if (songsRaw.isEmpty || sid == null) {
      notifyListeners();
      return;
    }
    final songs = songsRaw.map((e) => _songFromWire(Map<String, dynamic>.from(e as Map))).toList();
    final idx = (m['idx'] as num?)?.toInt() ?? 0;
    final playing = m['pl'] == true;
    final pos = (m['pos'] as num?)?.toInt() ?? 0;
    final at = (m['at'] as num?)?.toInt() ?? 0;
    // Where the host will be in ~3.5 s (time to load + buffer).
    final target = playing ? pos + (_hostNow - at) + 3500 : pos;
    _tl
      ..songId = sid
      ..posMs = pos
      ..atHost = at
      ..playing = playing;
    _guestLoadAndReport(songs, idx, target, lid: 0);
  }

  void _onLoad(Map<String, dynamic> m) {
    final songs = ((m['songs'] as List?) ?? const [])
        .map((e) => _songFromWire(Map<String, dynamic>.from(e as Map)))
        .toList();
    if (songs.isEmpty) return;
    final idx = (m['idx'] as num?)?.toInt() ?? 0;
    final pos = (m['pos'] as num?)?.toInt() ?? 0;
    final lid = (m['lid'] as num?)?.toInt() ?? 0;
    _tl
      ..songId = m['sid']?.toString()
      ..posMs = pos
      ..playing = false;
    _goTimer?.cancel();
    _guestLoadAndReport(songs, idx, pos, lid: lid);
  }

  Future<void> _guestLoadAndReport(List<Song> songs, int idx, int posMs, {required int lid}) async {
    await _applyLoad(songs, idx, posMs);
    if (_phase != JamPhase.inRoom) return;
    _send({'t': 'ready', 'lid': lid, 'rtt': _bestRtt()});
    // "go" arrived while we were still buffering (slow phone) → join the
    // running timeline a moment from now instead of staying silent.
    if (_tl.playing) {
      final at = _hostNow + 500;
      _scheduleStart(_tl.posMs + (at - _tl.atHost), at);
    }
  }

  void _onGo(Map<String, dynamic> m) {
    final pos = (m['pos'] as num).toInt();
    final at = (m['at'] as num).toInt();
    final sid = m['sid']?.toString();
    _tl
      ..songId = sid ?? _tl.songId
      ..posMs = pos
      ..atHost = at
      ..playing = true;
    if (_loading) return; // _guestLoadAndReport starts us once buffered
    _scheduleStart(pos, at);
  }

  void _onPauseMsg(Map<String, dynamic> m) {
    final pos = (m['pos'] as num).toInt();
    // The host repeats a pause for reliability — once we're settled, repeats do nothing.
    final settled = !_tl.playing && !_es.playing;
    _goTimer?.cancel();
    _tl
      ..posMs = pos
      ..atHost = _hostNow
      ..playing = false;
    if (!settled) {
      _graceUntil = _now() + 1500;
      _engine.pause();
      _engine.seek(Duration(milliseconds: pos));
    }
    if (m['hold'] == true) {
      _notice = JamNotice.waitingForFriend;
      notifyListeners();
    }
  }

  void _onTrack(Map<String, dynamic> m) {
    final sid = m['sid']?.toString();
    final at = (m['at'] as num?)?.toInt() ?? _hostNow;
    if (sid == null) return;
    _tl
      ..songId = sid
      ..posMs = 0
      ..atHost = at
      ..playing = true;
    _graceUntil = _now() + 2500;
    _songMismatchSince = 0;
    _driftSamples.clear();
  }

  void _onHeartbeat(Map<String, dynamic> m) {
    if (_loading) return;
    final pl = m['pl'] == true;
    final sid = m['sid']?.toString();
    final pos = (m['pos'] as num?)?.toInt() ?? 0;
    final at = (m['at'] as num?)?.toInt() ?? _hostNow;
    if (_notice == JamNotice.waitingForFriend && pl) {
      _notice = JamNotice.none;
      notifyListeners();
    }
    if (pl && _tl.playing && (sid == null || sid == _tl.songId)) {
      // The host's position is only sampled once a second (± ~100 ms noise).
      // Taking every heartbeat at face value shifted every guest's target
      // by that noise → constant corrections. Low-pass it; accept a real jump
      // (host seeked / stalled) immediately.
      final hostPosNow = pos + (_hostNow - at);
      final mine = _tl.posMs + (_hostNow - _tl.atHost);
      final diff = hostPosNow - mine;
      if (diff.abs() < 150) {
        _tl
          ..posMs = mine + (diff * 0.25).round()
          ..atHost = _hostNow;
      } else {
        _tl
          ..posMs = pos
          ..atHost = at;
      }
    } else {
      _tl
        ..songId = sid ?? _tl.songId
        ..posMs = pos
        ..atHost = at;
    }
    if (pl != _tl.playing) {
      _tl.playing = pl;
      if (!pl) {
        _engine.pause();
        _engine.seek(Duration(milliseconds: pos));
      }
    }
  }

  /// Guest watches itself: keeps the user from drifting the room apart by
  /// tapping the notification (pause / skip / resume).
  void _guestWatch(NativeEngineState s) {
    if (_loading) return;
    // Stall detection → ask the room to wait; tell it when we're back.
    final buffering = s.processingState == 'buffering' || s.processingState == 'loading';
    if (buffering && _tl.playing) {
      if (_stallSince == 0) _stallSince = _now();
      if (!_sentWait && _now() - _stallSince > 2500) {
        _sentWait = true;
        _send({'t': 'wait'});
      }
    } else {
      if (_sentWait && s.processingState == 'ready') {
        _send({'t': 'ready', 'lid': 0, 'stall': true});
      }
      _stallSince = 0;
      _sentWait = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // Shared: load paused → buffer → seek; scheduled start; drift loop
  // ══════════════════════════════════════════════════════════════════════
  Future<void> _applyLoad(List<Song> songs, int idx, int posMs) async {
    final p = _player;
    if (p == null || songs.isEmpty) return;
    _loading = true;
    _driftSamples.clear();
    _myStatus = 'syncing';
    _track();
    notifyListeners();
    try {
      final target = songs[idx.clamp(0, songs.length - 1).toInt()];
      await _engine.setJamHold(true);
      _goTimer?.cancel();

      final alreadyThere = _es.currentSongId == target.id && _es.processingState != 'idle';
      if (alreadyThere) {
        await _engine.pause();
      } else {
        await p.playSong(target, queue: songs, index: idx.clamp(0, songs.length - 1).toInt(), curatedQueue: true);
      }
      await _engine.pause();
      if (_phase != JamPhase.inRoom) {
        await _engine.pause(); // left while loading → stay silent
        return;
      }

      await _waitUntilReady(minBufferedMs: 0, timeoutMs: 20000);
      if (posMs > 0) {
        await _engine.seek(Duration(milliseconds: posMs));
        await Future.delayed(const Duration(milliseconds: 150));
        await _waitUntilReady(minBufferedMs: posMs + 6000, timeoutMs: 14000);
      } else {
        // Give the first seconds a moment to fill so playback never stalls
        // right after "go".
        await _waitUntilReady(minBufferedMs: 6000, timeoutMs: 12000);
      }
      await _engine.pause();
    } catch (e) {
      if (kDebugMode) debugPrint('[Jam] applyLoad failed: $e');
    } finally {
      _loading = false;
      _myStatus = 'ok';
      _track();
      notifyListeners();
    }
  }

  /// Pause + seek now, then start playback exactly at host-clock [atHost].
  void _scheduleStart(int posMs, int atHost) {
    _goTimer?.cancel();
    _driftSamples.clear();
    final localTarget = atHost - _offsetMs - _nudgeMs;
    var delay = localTarget - _now();
    var seekTo = posMs;
    if (delay < 0) {
      // We are late (slow network): skip ahead instead of starting behind.
      seekTo = posMs + (-delay);
      delay = 0;
    }
    _graceUntil = _now() + delay + 1600; // first drift check ~1.6 s after the start
    () async {
      try {
        await _engine.pause();
        await _engine.seek(Duration(milliseconds: seekTo));
      } catch (_) {}
    }();
    _goTimer = Timer(Duration(milliseconds: delay), () async {
      if (_phase != JamPhase.inRoom) return;
      try {
        await _engine.setJamHold(false);
        await _engine.play();
      } catch (_) {}
      _driftMs = 0;
      notifyListeners();
    });
  }

  /// 1 s heartbeat for drift (guests) and song-mismatch recovery.
  Future<void> _tick() async {
    if (_phase != JamPhase.inRoom) return;
    _livenessCheck();
    if (_isHost || _loading) return;
    final now = _now();
    if (now < _graceUntil) return;

    // Wrong song for too long (user skipped on their own) → re-sync.
    final want = _tl.songId;
    if (want != null && _es.currentSongId != null && _es.currentSongId != want) {
      if (_songMismatchSince == 0) _songMismatchSince = now;
      if (now - _songMismatchSince > 2500) {
        _songMismatchSince = 0;
        _send({'t': 'hello'});
        _graceUntil = now + 6000;
      }
      return;
    }
    _songMismatchSince = 0;

    if (!_tl.playing) return;

    // Guest paused locally while the room plays → resume on the timeline.
    if (!_es.playing && _es.processingState == 'ready') {
      final at = _hostNow + 400;
      _scheduleStart(_tl.posMs + (at - _tl.atHost), at);
      return;
    }
    if (!_es.playing || _es.processingState != 'ready') return;
    if (now - _esAtLocal > 1800) return; // stale data, don't act on it

    final expected = _tl.posMs + (_hostNow - _tl.atHost) + _nudgeMs;
    if (_lastDurMs > 0 && expected > _lastDurMs + 500) return;
    final raw = _estimatedPosMs() - expected; // + = we are ahead
    _driftSamples.add(raw);
    if (_driftSamples.length > 5) _driftSamples.removeAt(0);
    final sortedSamples = [..._driftSamples]..sort();
    // Median: one noisy reading can never trigger a correction by itself.
    final drift = sortedSamples[sortedSamples.length ~/ 2];
    final moved = (drift ~/ 20) != (_driftMs ~/ 20);
    _driftMs = drift;
    if (_driftSamples.length < 3) {
      if (moved) notifyListeners();
      return;
    }

    if (drift.abs() > _driftHardSeekMs) {
      // Really far off (long stall etc.) → one seek, then leave it alone a while.
      _graceUntil = now + 6000;
      _driftSamples.clear();
      try {
        await _engine.seek(Duration(milliseconds: max(0, expected + 150)));
        if (_curSpeed != 1.0) {
          _curSpeed = 1.0;
          _lastSpeedChangeAt = now;
          await _engine.setSpeed(1.0);
        }
      } catch (_) {}
    } else if (drift.abs() > _driftIgnoreMs) {
      // Small but steady gap → ONE gentle speed nudge (1.5 %), not more than
      // once per 5 s, so there is no speed "hunting" and no audible warble.
      if (now - _lastSpeedChangeAt > _speedChangeGapMs) {
        final step = drift.abs() > 200 ? 0.03 : 0.015; // bigger gap → slightly firmer nudge
        final want = drift > 0 ? 1.0 - step : 1.0 + step;
        if ((want - _curSpeed).abs() > 0.004) {
          _curSpeed = want;
          _lastSpeedChangeAt = now;
          _driftSamples.clear();
          try {
            await _engine.setSpeed(want);
          } catch (_) {}
        }
      }
    } else if (_curSpeed != 1.0 && drift.abs() < 40 && now - _lastSpeedChangeAt > 3000) {
      _curSpeed = 1.0;
      _lastSpeedChangeAt = now;
      try {
        await _engine.setSpeed(1.0);
      } catch (_) {}
    }
    // Refresh the live-offset readout only when it moved by ~20 ms or more.
    if (moved) notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════════
  // Stability helpers
  // ══════════════════════════════════════════════════════════════════════
  Future<void> _stopOwnPlayback() async {
    try {
      await _engine.pause();
    } catch (_) {}
    try {
      await _engine.setJamHold(false);
    } catch (_) {}
  }

  /// Bigger read-ahead buffer + larger rebuffer cushion while in a Jam.
  void _jamBuffer(bool on) {
    unawaited(() async {
      try {
        await _engine.setJamBuffer(on);
      } catch (_) {}
    }());
  }

  void _trackSoon() {
    if (_trackTimer != null) return;
    _trackTimer = Timer(const Duration(milliseconds: 1500), () {
      _trackTimer = null;
      if (_phase == JamPhase.inRoom) _track();
    });
  }

  @override
  void dispose() {
    _engineSub?.cancel();
    _connSub?.cancel();
    _stopTimers();
    unawaited(_closeWs());
    super.dispose();
  }
}
