import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

enum MusicSource { online, offline }

/// Tracks real network connectivity and switches between Online/Offline
/// music source automatically — but a manual toggle (e.g. from the
/// Playback Source sheet) always wins until the user changes it again.
///
/// - Internet available  → MusicSource.online  (stream from Saavn/YT)
/// - Internet unavailable → MusicSource.offline (local downloaded songs)
///
/// Switches instantly the moment connectivity changes (e.g. WiFi/mobile
/// data turns off or on), including stopping whatever is currently playing
/// so the UI never gets stuck pointing at a source that's no longer valid.
///
/// Manual override: if the user explicitly picks Online or Offline via
/// toggle(), that choice sticks even while the device still has internet —
/// auto-switching is suspended. The one exception is a real connectivity
/// LOSS: if the user manually forced Online but the network actually drops,
/// we still force Offline (a stream can't play with no internet regardless
/// of what was selected), and that clears the override.
class SourceProvider extends ChangeNotifier {
  MusicSource _source = MusicSource.online;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _manualOverride = false;
  bool _hasNetwork = true;

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

  Future<void> init() async {
    // Determine real status immediately at startup — don't wait for the
    // first connectivity change event.
    final initial = await Connectivity().checkConnectivity();
    _applyResult(initial, notify: false);

    // Listen for live changes — WiFi/mobile data toggling, airplane mode,
    // walking out of signal range, etc. Fires automatically going forward.
    _sub = Connectivity().onConnectivityChanged.listen(_applyResult);
  }

  void _applyResult(List<ConnectivityResult> results, {bool notify = true}) {
    _hasNetwork = results.any((r) => r != ConnectivityResult.none);

    // Real network loss always wins, even over a manual "Online" pick —
    // there's nothing to stream from with no internet.
    if (!_hasNetwork) {
      _manualOverride = false;
      _setSource(MusicSource.offline, notify: notify);
      return;
    }

    // Network is back, but the user manually chose a source — respect it
    // and don't auto-flip back to Online underneath them.
    if (_manualOverride) return;

    _setSource(MusicSource.online, notify: notify);
  }

  /// Manually pick a source. Stays in effect until the user toggles again,
  /// or until a real connectivity loss forces Offline (see _applyResult).
  void toggle() {
    final next = isOnline ? MusicSource.offline : MusicSource.online;
    // Can't manually force Online with no real network underneath.
    if (next == MusicSource.online && !_hasNetwork) return;
    _manualOverride = true;
    _setSource(next, notify: true);
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
    super.dispose();
  }
}
