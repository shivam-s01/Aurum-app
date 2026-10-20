// ═══════════════════════════════════════════════════════════════════════════
// FILE: lib/services/jam_service.dart
// DESCRIPTION: "Astra Jam" — group listening. Up to [maxMembers] phones play
//   the same song at the same moment, each streaming on its own.
//
// HOW IT STAYS LIGHT (low-end devices):
//   • No server code and no database tables: one Supabase Realtime channel
//     (broadcast + presence) per room, opened ONLY while you are in a room.
//   • Messages are tiny JSON (a few hundred bytes); only the host sends a
//     heartbeat (every 5 s). Guests run one 1.5 s drift check, and only while
//     a song is actually playing.
//   • Audio never travels through the host: every phone resolves and streams
//     the song itself, so nobody's hotspot is a bottleneck.
//
// HOW IT STAYS IN SYNC:
//   1. Clock sync  — a guest measures its clock offset to the host with
//      ping/pong (lowest-RTT samples win), so everybody shares one timeline.
//   2. Barrier     — on every song change the host says "load"; every phone
//      loads the song PAUSED, buffers, answers "ready"; only then the host
//      says "go at T+0.9 s". That is why playback starts without stutter.
//   3. Drift fix   — a guest that is a little off nudges its speed ±1-4 %
//      (inaudible); a guest that is far off seeks once.
//   4. Stall rule  — if one phone stalls, the room waits for it up to 4 s,
//      then carries on; that phone re-syncs by itself when it recovers.
//   5. Host leaves — the oldest guest becomes host automatically.
//
// NOTE: only online songs can be shared (local files exist on one phone).
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import 'auth_service.dart';
import 'native_engine_bridge.dart';

enum JamPhase { idle, connecting, previewing, inRoom }

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
}

class JamMember {
  final String id;
  final String name;
  final String? avatar;
  final bool isHost;
  final int joinedAt;
  final String status; // ok | buffering | syncing
  const JamMember({
    required this.id,
    required this.name,
    this.avatar,
    required this.isHost,
    required this.joinedAt,
    required this.status,
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
  static const String _alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  static const int _startDelayMs = 900; // go-signal lead time
  static const int _barrierTimeoutMs = 7000;
  static const int _stallHoldMs = 4000;
  static const int _driftIgnoreMs = 35;
  static const int _driftHardSeekMs = 200; // beyond this a quick seek beats seconds of speed-shifting
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

  /// One short line about the last connect attempt (socket status, presence
  /// snapshot, whois reply…). Shown in small text on the error card so a
  /// failure can be diagnosed from a screenshot.
  String debugInfo = '';
  String _subStatus = '-';
  Map<String, dynamic>? _iamHost; // host info learnt via broadcast (presence-independent)
  int _iamCount = 0;
  int _lastHostHeardAt = 0; // last time ANY message from the host arrived

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

  RealtimeChannel? _channel;
  int _channelGen = 0; // invalidates callbacks from an older channel

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

  // timers
  Timer? _hbTimer;
  Timer? _resubTimer;
  Timer? _busyRecheck;
  Timer? _driftTimer;
  Timer? _hostLostTimer;
  Timer? _peekTimer;

  /// Bumped by every leave() and every new create/peek. A create/peek that
  /// finds the number changed was cancelled (user tapped Cancel while
  /// connecting) and must stop without touching state.
  int _opSeq = 0;
  bool _presenceSynced = false; // first presence snapshot received on this channel
  Completer<void>? _presenceWake;
  int _graceUntil = 0;
  int _songMismatchSince = 0;
  double _curSpeed = 1.0;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void _wakeBarrier() {
    final c = _barrierWake;
    if (c != null && !c.isCompleted) c.complete();
  }
  int get _hostNow => _isHost ? _now() : _now() + _offsetMs;

  // ══════════════════════════════════════════════════════════════════════
  // Setup
  // ══════════════════════════════════════════════════════════════════════
  /// Safe to call many times; wires the player once.
  void attach(PlayerProvider player) {
    _player = player;
    _engineSub ??= _engine.stateStream.listen(_onEngineState);
  }

  Future<void> _loadPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _nudgeMs = (sp.getInt('jam_nudge_ms') ?? 0).clamp(-400, 400).toInt();
    } catch (_) {}
    final dn = (AuthService.instance.displayName ?? '').trim();
    _myName = dn.isEmpty ? 'Guest ${_myId.substring(0, 3).toUpperCase()}' : dn.split(' ').first;
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

  /// Opens the realtime socket early (call when the Jam page opens) so the
  /// websocket handshake is already done by the time the user taps Join.
  void warmUp() {
    try {
      Supabase.instance.client.realtime.connect();
    } catch (_) {}
  }

  static String sanitizeRoomName(String raw) {
    var s = raw.replaceAll(RegExp(r'[\n\r\t]'), ' ').trim();
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
    if (s.length > 24) s = s.substring(0, 24).trim();
    return s;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Create / peek / join / leave
  // ══════════════════════════════════════════════════════════════════════
  /// True when this create/peek was cancelled or replaced while it was
  /// awaiting. Closes the half-open channel only if nothing newer owns it.
  Future<bool> _superseded(int op) async {
    if (op == _opSeq) return false;
    if (_phase == JamPhase.idle) await _closeChannel();
    return true;
  }

  Future<bool> createRoom(String roomName) async {
    if (_phase != JamPhase.idle) await leave(silent: true);
    await _loadPrefs();
    final op = ++_opSeq;
    _phase = JamPhase.connecting;
    _notice = JamNotice.none;
    notifyListeners();

    // A random 6-char code collides ~never; still verify once or twice.
    for (var attempt = 0; attempt < 3; attempt++) {
      final code = _randomCode();
      final ok = await _openChannel(code);
      if (await _superseded(op)) return false;
      if (!ok) {
        debugInfo = 'create sub:$_subStatus';
        await _closeChannel();
        _fail(JamNotice.connectionFailed);
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 700)); // let presence sync
      if (await _superseded(op)) return false;
      if (_hostPresence() != null) {
        await _closeChannel();
        continue; // someone already hosts this code
      }
      _code = code;
      final clean = sanitizeRoomName(roomName);
      _roomName = clean.isEmpty ? '$_myName\u2019s Jam' : clean;
      _isHost = true;
      _joinedAt = _now();
      _offsetMs = 0;
      // The room must be visible to guests. Retry the presence announce a few
      // times; if it still isn't confirmed we carry on anyway \u2014 guests can also
      // find us through the broadcast "whois" fallback.
      for (var t = 0; t < 3; t++) {
        if (await _track()) break;
        await Future.delayed(const Duration(milliseconds: 500));
        if (await _superseded(op)) return false;
      }
      _phase = JamPhase.inRoom;
      _startRoomTimers();
      _seedTimelineFromEngine();
      // If something is already playing, start the room with it.
      _hostSyncNowPlaying();
      notifyListeners();
      return true;
    }
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
    // Up to 3 attempts. Each one re-opens the channel (a missed presence
    // snapshot is the classic cause of a false "Room not found") and asks the
    // host two ways: presence AND a broadcast "whois" that the host answers.
    // We only say "room not found" after every attempt came back empty.
    Map<String, dynamic>? host;
    var connected = false;
    _iamHost = null;
    _iamCount = 0;
    final tried = <String>[];
    for (var attempt = 0; attempt < 3 && host == null; attempt++) {
      final ok = await _openChannel(code);
      if (await _superseded(op)) return false;
      connected = ok;
      if (!ok) {
        tried.add('sub:$_subStatus');
        await _closeChannel();
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      host = await _waitForHost(maxMs: attempt == 0 ? 7000 : 5000);
      if (await _superseded(op)) return false;
      tried.add('ok presence:${_allPresence().length} synced:$_presenceSynced iam:${_iamHost != null}');
    }
    debugInfo = tried.join(' | ');
    if (kDebugMode) debugPrint('[Jam] peek $code → $debugInfo');
    if (!connected) {
      _fail(JamNotice.connectionFailed);
      return false;
    }
    if (host == null) {
      await _closeChannel();
      _fail(JamNotice.roomNotFound);
      return false;
    }
    final count = max(_allPresence().length, _iamCount);
    if (count >= maxMembers) {
      await _closeChannel();
      _fail(JamNotice.roomFull);
      return false;
    }
    _code = code;
    previewRoomName = (host['room'] ?? '').toString();
    previewHostName = (host['name'] ?? '').toString();
    previewSong = (host['song'] ?? '').toString();
    previewHostAvatar = host['avatar']?.toString();
    previewAvatars = _previewAvatarList();
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

  /// Resolves as soon as the host shows up in presence. Gives up after
  /// [maxMs], or [emptyGraceMs] after an EMPTY snapshot arrived (dead code).
  Future<Map<String, dynamic>?> _waitForHost({required int maxMs, int emptyGraceMs = 3600}) async {
    final start = _now();
    int? syncedAt;
    var lastWhois = 0;
    while (true) {
      final h = _hostPresence();
      if (h != null) return h;
      final iam = _iamHost;
      if (iam != null) return iam;
      final t = _now();
      if (t - start >= maxMs) return null;
      if (_presenceSynced) {
        syncedAt ??= t;
        if (t - syncedAt >= emptyGraceMs) return null;
      }
      // Ask the host directly (works even if presence is flaky). Repeat — a
      // broadcast sent a moment before the host's socket was ready is lost.
      if (t - lastWhois >= 1100) {
        lastWhois = t;
        _send({'t': 'whois'});
      }
      final c = _presenceWake = Completer<void>();
      await Future.any([c.future, Future.delayed(const Duration(milliseconds: 120))]);
    }
  }

  /// Host side: answer a "whois" with everything the preview card needs.
  void _sendIam(String to) {
    _send({
      't': 'iam',
      'to': to,
      'room': _roomName,
      'name': _myName,
      'song': _currentSongLabel(),
      'avatar': _myAvatar,
      'n': max(_allPresence().length, _members.length),
    });
  }

  /// Joins a room previously opened with [peek].
  Future<bool> join() async {
    if (_phase != JamPhase.previewing || _channel == null) return false;
    _peekTimer?.cancel();
    if (max(_allPresence().length, previewCount) >= maxMembers) {
      await leave(silent: true);
      _fail(JamNotice.roomFull);
      return false;
    }
    _isHost = false;
    _lastHostHeardAt = _now();
    _joinedAt = _now();
    _roomName = previewRoomName;
    _phase = JamPhase.inRoom;
    await _track();
    _startRoomTimers();
    _startClockSync();
    _send({'t': 'hello'});
    notifyListeners();
    return true;
  }

  Future<void> leave({bool silent = false}) async {
    _opSeq++;
    if (_phase == JamPhase.inRoom) _send({'t': 'bye'});
    _stopTimers();

    // Flip the UI to idle FIRST. Closing the channel below is a network call
    // that can take seconds on a bad connection — the user must not sit on
    // the room screen (and tap Leave twice) while it finishes.
    _phase = JamPhase.idle;
    previewHostAvatar = null;
    previewAvatars = const [];
    _isHost = false;
    _members = const [];
    _code = '';
    _roomName = '';
    _driftMs = 0;
    _inHold = false;
    _stalled.clear();
    _lastHoldAt.clear();
    _ready.clear();
    _tl
      ..songId = null
      ..playing = false
      ..posMs = 0;
    if (!silent) _notice = JamNotice.none;
    notifyListeners();

    await _closeChannel();
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

  // ══════════════════════════════════════════════════════════════════════
  // Channel plumbing
  // ══════════════════════════════════════════════════════════════════════
  Future<bool> _openChannel(String code) async {
    await _closeChannel();
    final gen = ++_channelGen;
    _presenceSynced = false;
    _presenceWake = null;
    final completer = Completer<bool>();
    try {
      final ch = Supabase.instance.client.channel(
        'astra_jam_$code',
        opts: RealtimeChannelConfig(self: false, key: _myId),
      );
      ch.onBroadcast(
        event: 'm',
        callback: (payload) {
          if (gen != _channelGen) return;
          try {
            final raw = payload['payload'];
            final m = raw is Map ? Map<String, dynamic>.from(raw) : Map<String, dynamic>.from(payload);
            _onMessage(m);
          } catch (e) {
            if (kDebugMode) debugPrint('[Jam] bad message: $e');
          }
        },
      );
      ch.onPresenceSync((_) {
        if (gen != _channelGen) return;
        _onPresenceSync();
      });
      ch.subscribe((status, error) {
        if (gen != _channelGen) return;
        _subStatus = error == null ? status.name : '${status.name}(${error.toString().split('\n').first})';
        if (kDebugMode) debugPrint('[Jam] channel $code → $_subStatus');
        if (status == RealtimeSubscribeStatus.subscribed) {
          if (!completer.isCompleted) completer.complete(true);
          // Re-subscribed after a drop: re-announce so the room re-syncs us.
          if (_phase == JamPhase.inRoom) {
            _track();
            if (!_isHost) _send({'t': 'hello'});
            if (_notice == JamNotice.reconnecting) {
              _notice = JamNotice.none;
              notifyListeners();
            }
          }
        } else if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          if (!completer.isCompleted) {
            completer.complete(false);
          } else if (_phase == JamPhase.inRoom) {
            _notice = JamNotice.reconnecting;
            notifyListeners();
            _scheduleResubscribe();
          }
        }
      });
      _channel = ch;
    } catch (_) {
      return false;
    }
    return completer.future.timeout(const Duration(seconds: 8), onTimeout: () => false);
  }

  /// The realtime library retries a dropped channel by itself, but on some
  /// phones it stays stuck. If we're still "reconnecting" after a few
  /// seconds, tear the channel down and subscribe again (the subscribed
  /// callback re-announces us to the room).
  void _scheduleResubscribe() {
    _resubTimer?.cancel();
    final gen = _channelGen;
    _resubTimer = Timer(const Duration(seconds: 6), () async {
      if (gen != _channelGen || _phase != JamPhase.inRoom || _notice != JamNotice.reconnecting) return;
      final ok = await _openChannel(_code);
      if (!ok && _phase == JamPhase.inRoom && _notice == JamNotice.reconnecting) _scheduleResubscribe();
    });
  }

  Future<void> _closeChannel() async {
    _channelGen++;
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      // Time-boxed: on a bad connection these calls can hang for 10 s+, which
      // used to freeze every retry ("connect hi nahi ho raha").
      try {
        await ch.untrack().timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await Supabase.instance.client.removeChannel(ch).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  void _send(Map<String, dynamic> m) {
    final ch = _channel;
    if (ch == null) return;
    m['f'] = _myId;
    try {
      ch.sendBroadcastMessage(event: 'm', payload: m);
    } catch (_) {}
  }

  /// A pause is the one message that must never be lost, and broadcasts are
  /// fire-and-forget. Send it again shortly after (only while still paused);
  /// guests treat repeats as no-ops.
  void _sendBurst(Map<String, dynamic> m) {
    _send(m);
    for (final ms in const [350, 1100]) {
      Timer(Duration(milliseconds: ms), () {
        if (_isHost && _phase == JamPhase.inRoom && !_tl.playing) _send(Map<String, dynamic>.of(m));
      });
    }
  }

  Map<String, dynamic> _presencePayload() => {
        'id': _myId,
        'name': _myName,
        'avatar': _myAvatar,
        'host': _isHost,
        'joined': _joinedAt,
        'status': _myStatus,
        if (_isHost) 'room': _roomName,
        if (_isHost) 'song': _currentSongLabel(),
      };

  /// Announces us in presence. Returns true when the server confirmed it.
  Future<bool> _track() async {
    final ch = _channel;
    if (ch == null) return false;
    try {
      final dynamic r = await ch.track(_presencePayload()).timeout(const Duration(seconds: 5));
      final s = r.toString().toLowerCase();
      return s == 'ok' || s.endsWith('.ok');
    } catch (e) {
      if (kDebugMode) debugPrint('[Jam] track failed: $e');
      return false;
    }
  }

  String _currentSongLabel() {
    final s = _player?.currentSong;
    if (s == null) return '';
    return '${s.title} \u2022 ${s.artist}';
  }

  List<Map<String, dynamic>> _allPresence() {
    final out = <Map<String, dynamic>>[];
    final ch = _channel;
    if (ch == null) return out;
    try {
      for (final st in ch.presenceState()) {
        for (final p in st.presences) {
          out.add(Map<String, dynamic>.from(p.payload));
        }
      }
    } catch (_) {}
    return out;
  }

  List<String?> _previewAvatarList() =>
      _allPresence().map((p) => p['avatar']?.toString()).toList();

  Map<String, dynamic>? _hostPresence() {
    final hosts = _allPresence().where((m) => m['host'] == true).toList();
    if (hosts.isEmpty) return null;
    hosts.sort((a, b) => ((a['joined'] ?? 0) as num).compareTo((b['joined'] ?? 0) as num));
    return hosts.first;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Presence → members, host election
  // ══════════════════════════════════════════════════════════════════════
  void _onPresenceSync() {
    _presenceSynced = true;
    final pw = _presenceWake;
    if (pw != null && !pw.isCompleted) pw.complete();
    final all = _allPresence();
    if (_phase == JamPhase.previewing) {
      previewCount = all.length;
      final h = _hostPresence();
      if (h != null) {
        previewRoomName = (h['room'] ?? '').toString();
        previewHostName = (h['name'] ?? '').toString();
        previewSong = (h['song'] ?? '').toString();
        previewHostAvatar = h['avatar']?.toString();
      }
      previewAvatars = _previewAvatarList();
      notifyListeners();
      return;
    }
    if (_phase != JamPhase.inRoom) return;

    if (!_isHost && all.length > maxMembers) {
      final byJoin = [...all]..sort((a, b) {
          final c = ((a['joined'] ?? 0) as num).compareTo((b['joined'] ?? 0) as num);
          return c != 0 ? c : (a['id'] ?? '').toString().compareTo((b['id'] ?? '').toString());
        });
      if (byJoin.indexWhere((m) => m['id'] == _myId) >= maxMembers) {
        unawaited(leave(silent: true)); // flips the UI to idle immediately
        _notice = JamNotice.roomFull;
        notifyListeners();
        return;
      }
    }

    final hostEntry = _hostPresence();
    final hostId = hostEntry == null ? null : hostEntry['id'];

    // Two hosts (a reconnect raced an election): the older one wins.
    if (_isHost && hostEntry != null && hostId != _myId) {
      _demoteToGuest();
    }

    // Host vanished → deterministic election by oldest join.
    if (hostEntry == null && !_isHost) {
      _hostLostTimer ??= Timer(const Duration(seconds: 6), () {
        _hostLostTimer = null;
        if (_phase != JamPhase.inRoom || _isHost) return;
        final now = _allPresence();
        if (now.any((m) => m['host'] == true)) return;
        // Host still talking to us (heartbeat every 5 s) → it's just a presence
        // hiccup, not a real departure. Don't steal the room.
        if (_now() - _lastHostHeardAt < 12000) return;
        now.sort((a, b) {
          final c = ((a['joined'] ?? 0) as num).compareTo((b['joined'] ?? 0) as num);
          return c != 0 ? c : (a['id'] ?? '').toString().compareTo((b['id'] ?? '').toString());
        });
        if (now.isNotEmpty && now.first['id'] == _myId) {
          _promoteToHost();
        } else if (now.length <= 1) {
          // Alone and not first? (can't happen) — end gracefully.
          _notice = JamNotice.hostEnded;
          leave(silent: true);
        }
      });
    } else if (hostEntry != null) {
      _hostLostTimer?.cancel();
      _hostLostTimer = null;
      if (!_isHost && (hostEntry['room'] ?? '').toString().isNotEmpty) {
        _roomName = hostEntry['room'].toString();
      }
    }

    _members = all
        .map((m) => JamMember(
              id: (m['id'] ?? '').toString(),
              name: (m['name'] ?? 'Guest').toString(),
              avatar: m['avatar']?.toString(),
              isHost: m['host'] == true,
              joinedAt: ((m['joined'] ?? 0) as num).toInt(),
              status: (m['status'] ?? 'ok').toString(),
            ))
        .toList()
      ..sort((a, b) {
        if (a.isHost != b.isHost) return a.isHost ? -1 : 1;
        return a.joinedAt.compareTo(b.joinedAt);
      });
    notifyListeners();
  }

  void _promoteToHost() {
    _isHost = true;
    _offsetMs = 0;
    _notice = JamNotice.youAreHostNow;
    _pingTimer?.cancel();
    _seedTimelineFromEngine();
    _track();
    _startRoomTimers();
    notifyListeners();
  }

  void _demoteToGuest() {
    _isHost = false;
    _hbTimer?.cancel();
    _track();
    _startClockSync();
    _send({'t': 'hello'});
    notifyListeners();
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
    _hostLostTimer?.cancel();
    _peekTimer?.cancel();
    _resubTimer?.cancel();
    _busyRecheck?.cancel();
    _hbTimer = _busyRecheck = _driftTimer = _pingTimer = _goTimer = _holdTimer = _hostLostTimer = _peekTimer = _resubTimer = null;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Clock sync (guest)
  // ══════════════════════════════════════════════════════════════════════
  void _startClockSync() {
    _clockSamples.clear();
    _pingsLeftInBurst = 6;
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (_phase != JamPhase.inRoom || _isHost) {
        t.cancel();
        return;
      }
      _send({'t': 'ping', 't0': _now()});
      if (--_pingsLeftInBurst <= 0) {
        t.cancel();
        // After the burst, one refresh every 12 s keeps the offset fresh.
        _pingTimer = Timer.periodic(const Duration(seconds: 12), (t2) {
          if (_phase != JamPhase.inRoom || _isHost) {
            t2.cancel();
            return;
          }
          _send({'t': 'ping', 't0': _now()});
        });
      }
    });
  }

  void _onPong(Map<String, dynamic> m) {
    if (m['to'] != _myId) return;
    final t0 = (m['t0'] as num).toInt();
    final th = (m['th'] as num).toInt();
    final t1 = _now();
    final rtt = t1 - t0;
    if (rtt < 0 || rtt > 3000) return;
    final offset = th - (t0 + rtt ~/ 2);
    _clockSamples.add([rtt, offset]);
    if (_clockSamples.length > 12) _clockSamples.removeAt(0);
    final sorted = [..._clockSamples]..sort((a, b) => a[0].compareTo(b[0]));
    final best = sorted.take(3).toList();
    _offsetMs = (best.fold<int>(0, (s, e) => s + e[1]) / best.length).round();
  }

  // ══════════════════════════════════════════════════════════════════════
  // Message router
  // ══════════════════════════════════════════════════════════════════════
  void _onMessage(Map<String, dynamic> m) {
    final from = (m['f'] ?? '').toString();
    final type = (m['t'] ?? '').toString();
    final to = m['to']?.toString();
    if (to != null && to != _myId) return;

    // Presence-independent host discovery (used while joining by code).
    if (type == 'iam') {
      if (_phase == JamPhase.connecting && _iamHost == null) {
        _iamCount = (m['n'] as num?)?.toInt() ?? 0;
        _iamHost = {
          'room': m['room'],
          'name': m['name'],
          'song': m['song'],
          'avatar': m['avatar'],
          'host': true,
        };
        final pw = _presenceWake;
        if (pw != null && !pw.isCompleted) pw.complete();
      }
      return;
    }
    if (type == 'whois') {
      if (_isHost && _phase == JamPhase.inRoom) _sendIam(from);
      return;
    }

    if (_phase != JamPhase.inRoom) return;
    // Any traffic from the host proves it is alive, even if presence glitches.
    if (!_isHost && (type == 'hb' || type == 'state' || type == 'pong' || type == 'load' || type == 'go' || type == 'pause' || type == 'track')) {
      _lastHostHeardAt = _now();
    }

    switch (type) {
      // ── host-bound ──
      case 'ping':
        if (_isHost) _send({'t': 'pong', 'to': from, 't0': m['t0'], 'th': _now()});
        break;
      case 'hello':
        if (_isHost) _sendStateTo(from);
        break;
      case 'ready':
        if (_isHost) _onReady(from, (m['lid'] as num?)?.toInt() ?? 0, m['stall'] == true);
        break;
      case 'wait':
        if (_isHost) _onWait(from);
        break;
      case 'bye':
        _stalled.remove(from);
        if (_isHost) _wakeBarrier();
        break;

      // ── guest-bound ──
      case 'pong':
        _onPong(m);
        break;
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

    // My own status for the member list (only publish on change).
    final st = (s.processingState == 'buffering' || s.processingState == 'loading') ? 'buffering' : 'ok';
    if (st != _myStatus && !_loading) {
      _myStatus = st;
      _track();
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
      ..atHost = _now()
      ..playing = _es.playing;
  }

  void _hostSyncNowPlaying() {
    final s = _player?.currentSong;
    if (s == null || s.isLocal) return;
    // Something already playing: put everyone (just the host for now) on the
    // barrier path so late joiners find a consistent timeline.
    _seedTimelineFromEngine();
  }

  bool get _alone => !_members.any((m) => m.id != _myId);

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
        ..atHost = _now()
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
      final guests = _members.where((m) => m.id != _myId).map((m) => m.id).toSet();
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

  void _onReady(String from, int lid, bool stall) {
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
      final at = _hostNow + _startDelayMs;
      final pos = _hostPosNow() + _startDelayMs;
      _send({'t': 'go', 'to': from, 'pos': pos, 'at': at, 'lid': lid, 'sid': _tl.songId});
    }
  }

  void _hostGo(int posMs, {int lid = 0}) {
    // Alone in the room → nobody to wait for, start almost instantly.
    final at = _hostNow + (_alone ? 120 : _startDelayMs);
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
        ..atHost = _now()
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
    _send({'t': 'ready', 'lid': lid});
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
    _tl
      ..songId = sid ?? _tl.songId
      ..posMs = pos
      ..atHost = at;
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
      if (!_sentWait && _now() - _stallSince > 1200) {
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

      await _waitUntilReady(minBufferedMs: 0, timeoutMs: 12000);
      if (posMs > 0) {
        await _engine.seek(Duration(milliseconds: posMs));
        await Future.delayed(const Duration(milliseconds: 150));
        await _waitUntilReady(minBufferedMs: posMs + 4000, timeoutMs: 8000);
      } else {
        // Give the first seconds a moment to fill so playback never stalls
        // right after "go".
        await _waitUntilReady(minBufferedMs: 3000, timeoutMs: 6000);
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
    final localTarget = atHost - (_isHost ? 0 : _offsetMs) - _nudgeMs;
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
    if (_phase != JamPhase.inRoom || _isHost || _loading) return;
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
    final drift = _estimatedPosMs() - expected; // + = we are ahead
    final moved = (drift ~/ 10) != (_driftMs ~/ 10);
    _driftMs = drift;

    if (drift.abs() > _driftHardSeekMs) {
      _graceUntil = now + 2500;
      try {
        await _engine.seek(Duration(milliseconds: expected + 120));
        if (_curSpeed != 1.0) {
          _curSpeed = 1.0;
          await _engine.setSpeed(1.0);
        }
      } catch (_) {}
    } else if (drift.abs() > _driftIgnoreMs) {
      final rate = (drift.abs() / 1500).clamp(0.01, 0.04).toDouble();
      final want = drift > 0 ? 1.0 - rate : 1.0 + rate;
      if ((want - _curSpeed).abs() > 0.004) {
        _curSpeed = want;
        try {
          await _engine.setSpeed(want);
        } catch (_) {}
      }
    } else if (_curSpeed != 1.0 && drift.abs() < 15) {
      _curSpeed = 1.0;
      try {
        await _engine.setSpeed(1.0);
      } catch (_) {}
    }
    // Refresh the live-offset readout only when it moved by ~10 ms or more.
    if (moved) notifyListeners();
  }

  @override
  void dispose() {
    _engineSub?.cancel();
    _stopTimers();
    super.dispose();
  }
}
