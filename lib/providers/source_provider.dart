import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

enum MusicSource { online, offline }

/// Automatically tracks real network connectivity and switches between
/// Online/Offline music source — no manual toggle needed.
///
/// - Internet available  → MusicSource.online  (stream from Saavn/YT)
/// - Internet unavailable → MusicSource.offline (local downloaded songs)
///
/// Switches instantly the moment connectivity changes (e.g. WiFi/mobile
/// data turns off or on), including stopping whatever is currently playing
/// so the UI never gets stuck pointing at a source that's no longer valid.
class SourceProvider extends ChangeNotifier {
  MusicSource _source = MusicSource.online;
  StreamSubscription<List<ConnectivityResult>>? _sub;

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
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    final newSource = hasNetwork ? MusicSource.online : MusicSource.offline;

    if (newSource == _source) return; // no actual change, skip

    _source = newSource;
    if (notify) {
      // Real-time change while app is running — stop whatever's currently
      // playing immediately, since its source (stream URL or local file)
      // is no longer valid for the new mode.
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
