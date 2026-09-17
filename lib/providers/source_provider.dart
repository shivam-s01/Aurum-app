import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MusicSource { online, offline }

/// Tracks real network connectivity and switches between Online/Offline
/// music source automatically.
///
/// - Internet available  → MusicSource.online  (stream from Saavn/YT)
/// - Internet unavailable → MusicSource.offline (local downloaded songs)
///
/// Switches the moment connectivity changes (e.g. WiFi/mobile data turns
/// off or on), including stopping whatever is currently playing so the UI
/// never gets stuck pointing at a source that's no longer valid. Going
/// offline applies instantly; coming back online is debounced (see
/// _reconnectDebounce) so a flaky signal doesn't flicker the source
/// back and forth.
///
/// Offline Mode (Spotify-style data saver): a standalone setting, not a
/// manual "pick your source" toggle. When the user turns it on in
/// Settings, the app stays on MusicSource.offline and never streams —
/// even with a perfectly good connection — exactly like Spotify's
/// Settings → Offline Mode. It has nothing to do with real connectivity:
/// turning it off just means "go back to following the network", not
/// "force Online". See setOfflineMode().
class SourceProvider extends ChangeNotifier {
  MusicSource _source = MusicSource.online;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _hasNetwork = true;
  bool _offlineModeEnabled = false;

  static const _offlineModePrefsKey = 'offline_mode_enabled';

  // Debounce for flaky signal (elevator, tunnel, weak WiFi handoff): a
  // connectivity event that reverses itself within this window never
  // reaches _setSource at all, so the UI/playback never sees the flicker.
  // Only the RECOVERY side (offline -> online) is debounced — going
  // offline still applies instantly, because riding out a dead stream is
  // worse than a possibly-premature pause (see hasPlaybackBuffer, which
  // already covers "don't yank audio the instant signal drops"). Debouncing
  // the drop too would just add a second, redundant delay on top of that
  // buffer-riding logic.
  static const _reconnectDebounce = Duration(seconds: 2);
  Timer? _reconnectTimer;

  /// Called by playback code (e.g. PlayerProvider) whenever the source
  /// flips, so the currently playing song can be stopped immediately.
  void Function()? onSourceChanged;

  /// Optional check wired in from main.dart once PlayerProvider exists:
  /// returns true if the song currently loaded in the engine is a local
  /// file. When true, a connectivity drop does NOT stop playback — a
  /// local file doesn't need internet to keep playing, exactly like
  /// Spotify keeps an already-downloaded/offline track going. Only an
  /// online stream gets interrupted, since it genuinely can't continue
  /// without network.
  bool Function()? isCurrentSongLocal;

  /// Optional check wired in from main.dart: returns true if the engine
  /// currently has enough buffered audio to keep playing for a bit even
  /// with no network. Spotify doesn't yank a track the instant a signal
  /// drop is detected — it keeps riding the buffer and only actually
  /// interrupts once that buffer is exhausted and the player itself
  /// stalls. When this returns true we skip the immediate stop here and
  /// let the engine's own buffering/stall callback (see PlayerProvider)
  /// decide if/when playback truly needs to pause.
  bool Function()? hasPlaybackBuffer;

  /// Called whenever connectivity genuinely comes back (offline → online,
  /// driven by a real network event — never by the user's manual toggle).
  /// Spotify-style: reconnecting doesn't just flip a status pill, it picks
  /// the interrupted stream back up automatically so the user doesn't have
  /// to notice playback died and tap play again themselves. Wired in
  /// main.dart to resume/replay whatever song was current when the drop
  /// happened, but only if it actually needs it (see the call site for
  /// the "was this song genuinely interrupted" check) — this fires on
  /// every reconnect, including ones where playback never actually
  /// stopped (e.g. it was still riding its buffer, or the current song
  /// was local), so the callback itself is responsible for deciding
  /// whether there's anything to resume.
  void Function()? onReconnected;

  MusicSource get source => _source;
  bool get isOnline => _source == MusicSource.online;
  bool get hasNetwork => _hasNetwork;
  bool get isOfflineModeEnabled => _offlineModeEnabled;

  Future<void> init() async {
    // Restore Offline Mode before the first connectivity check runs, so
    // a real network result never briefly flips to Online before the
    // saved preference is applied on top of it.
    final prefs = await SharedPreferences.getInstance();
    _offlineModeEnabled = prefs.getBool(_offlineModePrefsKey) ?? false;

    // Determine real status immediately at startup — don't wait for the
    // first connectivity change event.
    final initial = await Connectivity().checkConnectivity();
    _applyResult(initial, notify: false);

    // Listen for live changes — WiFi/mobile data toggling, airplane mode,
    // walking out of signal range, etc. Fires automatically going forward.
    _sub = Connectivity().onConnectivityChanged.listen(_applyResult);
  }

  /// Spotify-style Offline Mode. ON: stay on MusicSource.offline
  /// regardless of real connectivity — nothing streams, even with a
  /// perfectly good connection, until the user turns this back off.
  /// OFF: go back to purely following real connectivity (_applyResult),
  /// same as if Offline Mode never existed — NOT a forced switch to
  /// Online, since there may genuinely be no network right now.
  Future<void> setOfflineMode(bool enabled) async {
    if (_offlineModeEnabled == enabled) return;
    _offlineModeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_offlineModePrefsKey, enabled);

    if (enabled) {
      // Cancel any in-flight reconnect debounce — it must not flip to
      // Online after the user just explicitly asked to stay offline.
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _setSource(MusicSource.offline, notify: true);
    } else {
      // Re-evaluate real connectivity right now instead of waiting for
      // the next connectivity event — if the network's been fine the
      // whole time, this should flip back to Online immediately.
      final current = await Connectivity().checkConnectivity();
      _applyResult(current, notify: true);
    }
  }

  void _applyResult(List<ConnectivityResult> results, {bool notify = true}) {
    final hasNetworkNow = results.any((r) => r != ConnectivityResult.none);
    _hasNetwork = hasNetworkNow;

    // Offline Mode overrides real connectivity entirely — the user asked
    // to stay offline regardless of what the network is doing. Still
    // track _hasNetwork above (so turning Offline Mode back off knows
    // the real state immediately), just don't act on it here.
    if (_offlineModeEnabled) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _setSource(MusicSource.offline, notify: notify);
      return;
    }

    // Real network loss — nothing to stream from with no internet.
    // Applied instantly, and it also cancels any pending reconnect
    // debounce — a drop-then-flicker-back-then-drop-again sequence should
    // not let a stale timer fire "online" after we've already gone
    // offline for a real reason.
    if (!hasNetworkNow) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _setSource(MusicSource.offline, notify: notify);
      return;
    }

    // Already online — nothing changed, and no flicker to guard against.
    if (_source == MusicSource.online) return;

    // Signal just came back after being down. Don't trust it immediately
    // — flaky spots report "connected" for a moment during a handoff and
    // then drop again a second later. Wait for the signal to hold for
    // _reconnectDebounce before actually flipping to Online and resuming
    // playback; if another change (flicker back to none) arrives before
    // the timer fires, it's cancelled here and the offline branch above
    // runs instead, so a genuine flicker never reaches _setSource at all.
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDebounce, () {
      _reconnectTimer = null;
      // Re-check — by the time this fires, connectivity may have moved
      // again while we were waiting.
      if (!_hasNetwork) return;
      _setSource(MusicSource.online, notify: notify);
    });
  }

  void _setSource(MusicSource next, {required bool notify}) {
    if (next == _source) return; // no actual change, skip
    final previous = _source;
    _source = next;
    if (notify) {
      // A local file keeps playing fine with no network — only consider
      // stopping playback when the current song actually depends on the
      // network (an online stream). Falls back to the old "always stop"
      // behavior if the check hasn't been wired up yet, so this never
      // regresses into "nothing was stopped and the mini player looks
      // stuck".
      final currentIsLocal = isCurrentSongLocal?.call() ?? false;
      // Spotify-style: don't cut a stream the instant connectivity drops.
      // If there's still audio sitting in the engine's buffer, let it keep
      // playing — the engine's own stall/error callback is what actually
      // pauses playback once that buffer runs out and there's genuinely
      // nothing left to play.
      final stillBuffered = hasPlaybackBuffer?.call() ?? false;
      if (!currentIsLocal && !stillBuffered) {
        onSourceChanged?.call();
      }
      // Spotify-style auto-resume: connectivity genuinely coming back
      // (offline → online) is the one transition that should proactively
      // try to pick playback back up, rather than leaving a dead/paused
      // stream sitting there until the user notices and taps play again.
      if (previous == MusicSource.offline && next == MusicSource.online) {
        onReconnected?.call();
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
