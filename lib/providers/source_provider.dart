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
    _source = next;
    if (notify) {
      // Stop whatever's currently playing immediately, since its source
      // (stream URL or local file) is no longer valid for the new mode.
      onSourceChanged?.call();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
