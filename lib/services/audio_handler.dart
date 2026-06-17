import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'api_service.dart';
import 'audio_prefs.dart';

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player   = AudioPlayer();
  final _playlist = ConcatenatingAudioSource(children: []);

  List<Song> _queue        = [];
  int        _currentIndex = 0;

  // Fired synchronously the instant _queue/_currentIndex change — lets
  // PlayerProvider notify the UI immediately (new "now playing" song,
  // equalizer icon, mini-player) without waiting for currentIndexStream,
  // which only fires once just_audio finishes loading the resolved source.
  void Function()? onQueueChanged;

  // Cancellation token — each new playQueue/playSong call gets a fresh ID.
  // Background resolvers check this before touching the playlist.
  int _playSessionId = 0;

  // Prevent concurrent playQueue calls from racing each other.
  bool _isLoadingNewSong = false;

  // True while _resolveQueueInBackground is still splicing songs into the
  // live ConcatenatingAudioSource. During this window the player's own
  // internal sequence index does NOT correspond 1:1 with `_currentIndex`
  // (which tracks position within the full `_queue`), because the player
  // starts with just one song and grows toward the full queue size. The
  // currentIndexStream listener below must ignore index updates while this
  // is true, otherwise it stomps `_currentIndex` with a stale/mismatched
  // value and the UI appears to jump to a different song mid-playback.
  bool _splicingInProgress = false;

  StreamSubscription<AccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime.now();
  static const double _shakeThreshold = 15.0;

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // Restore Player & Audio settings (Stream Quality, Data Saver, call /
    // notification interruption behaviour) BEFORE the audio session is
    // wired up — so the very first interruption event already respects them.
    await AudioPrefs.load();

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // ---------------------------------------------------------------------
    // Interruption handling — driven by Settings → Player & Audio →
    // Behaviour:
    //
    //   • AudioInterruptionType.pause → typically a phone call or another
    //     media app taking over.
    //       - AudioPrefs.pauseOnCall == true  (default): pause, and resume
    //         automatically once the interruption ends.
    //       - AudioPrefs.pauseOnCall == false: ignored entirely — playback
    //         keeps going through calls wherever the OS allows it.
    //
    //   • AudioInterruptionType.duck → a short transient sound (e.g. a
    //     notification chime).
    //       - AudioPrefs.duckOnNotifications == false (default): IGNORED —
    //         song volume does NOT drop and playback does NOT pause for
    //         notifications.
    //       - true: pause briefly and resume after, like other apps do.
    // ---------------------------------------------------------------------
    session.interruptionEventStream.listen((event) {
      final isDuck = event.type == AudioInterruptionType.duck;

      if (isDuck && !AudioPrefs.duckOnNotifications) {
        return; // Notification sound — ignore, keep playing at full volume.
      }
      if (!isDuck && !AudioPrefs.pauseOnCall) {
        return; // Phone call / other app — ignore, keep playing.
      }

      if (event.begin) {
        _player.pause();
      } else {
        _player.play();
      }
    });

    session.becomingNoisyEventStream.listen((_) => _player.pause());

    _player.playbackEventStream.listen(_broadcastState);

    _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    _player.currentIndexStream.listen((index) {
      // FIX: while songs are still being spliced into the live player
      // sequence (playQueue's background prepend/append phase), the
      // player's own index is NOT the same coordinate space as
      // `_currentIndex` (queue position) — trusting it here caused the
      // displayed "now playing" song to jump around on its own.
      if (_splicingInProgress) return;
      if (index != null && index != _currentIndex && index < _queue.length) {
        _currentIndex = index;
        _updateMediaItem(_queue[index]);
      }
    });

    await _applySettings();
  }

  Future<void> _applySettings() async {
    await AudioPrefs.load();
    final p = await SharedPreferences.getInstance();
    final speed = p.getDouble('playback_speed') ?? 1.0;
    await _player.setSpeed(speed);
    final shakeEnabled = p.getBool('shake_to_skip') ?? false;
    _updateShakeListener(shakeEnabled);
  }

  void _updateShakeListener(bool enabled) {
    _shakeSub?.cancel();
    _shakeSub = null;
    if (!enabled) return;
    _shakeSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final now = DateTime.now();
      if (magnitude > _shakeThreshold && now.difference(_lastShake).inMilliseconds > 1000) {
        _lastShake = now;
        skipToNext();
      }
    });
  }

  Future<void> reloadSettings() async => _applySettings();

  @override
  Future<void> onTaskRemoved() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('stop_on_swipe') ?? false) {
      await stop();
      await clearQueue();
    }
  }

  @override
  Future<void> onNotificationDeleted() async => stop();

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'reloadSettings') await reloadSettings();
  }

  Future<AudioSource?> _sourceForSong(Song song) async {
    if (song.isLocal) {
      final path = song.localPath!;
      final uri = path.startsWith('content://') || path.startsWith('file://')
          ? Uri.parse(path)
          : Uri.file(path);
      return AudioSource.uri(uri, tag: _songToMediaItem(song));
    }
    final url = await ApiService.resolveStreamUrl(song);
    if (url == null) return null;
    return AudioSource.uri(Uri.parse(url), tag: _songToMediaItem(song));
  }

  Future<void> _reapplySpeed() async {
    final p = await SharedPreferences.getInstance();
    await _player.setSpeed(p.getDouble('playback_speed') ?? 1.0);
  }

  // ─── MAIN PLAY ENTRY POINT ───────────────────────────────────────────────
  //
  // Strategy:
  //   1. Bump session ID — cancels any in-flight background resolver immediately.
  //   2. Stop player hard — guarantees old audio dies before new starts.
  //   3. Resolve only the clicked song URL (fast).
  //   4. Build a fresh ConcatenatingAudioSource with just that one song.
  //   5. setAudioSource → play → done. UI responds instantly.
  //   6. Background: resolve remaining songs and splice them in safely,
  //      always checking session ID so a subsequent tap cancels this work.

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    // Debounce rapid taps — if already loading, cancel previous and take over
    _playSessionId++;
    final mySession = _playSessionId;
    _isLoadingNewSong = true;

    // Set queue/index synchronously, before any async gap, so currentSong
    // reflects the tapped song the instant this function is called — the
    // UI doesn't have to wait for stop()/resolve() to see the new "now
    // playing" state.
    //
    // FIX: _currentIndex must match startIndex's position in `_queue`
    // (the full, original-order list) from the very first frame.
    // The player's OWN ConcatenatingAudioSource starts with just one
    // song at player-index 0 (see below), which is a SEPARATE notion
    // of "index" from this one — _currentIndex tracks position within
    // `_queue`/`songs`, not within the live player sequence. Setting
    // this to 0 unconditionally caused currentSong to point at the
    // wrong song whenever startIndex > 0 (i.e. any tap that wasn't the
    // first item in a playlist), and the desync only "resolved itself"
    // once the background prepend loop finished — which looked like
    // the song randomly changing mid-playback.
    _queue        = List<Song>.from(songs);
    _currentIndex = startIndex;
    _splicingInProgress = true; // raised until background splice finishes
    onQueueChanged?.call();

    try {
      // 1. Hard stop — old song dies immediately, no bleed-through
      await _player.stop();

      // Check if superseded by an even newer tap
      if (mySession != _playSessionId) { return; }

      // 2. Resolve clicked song
      final startSource = await _sourceForSong(songs[startIndex]);
      if (mySession != _playSessionId) { return; }
      if (startSource == null) { _splicingInProgress = false; return; }

      // 3. Fresh single-song playlist — no placeholders, no auto-skip
      final fresh = ConcatenatingAudioSource(children: [startSource]);
      await _player.setAudioSource(fresh, initialIndex: 0, preload: true);
      if (mySession != _playSessionId) { return; }

      await _reapplySpeed();
      _updateMediaItem(songs[startIndex]);
      await _player.play();

    } finally {
      if (mySession == _playSessionId) _isLoadingNewSong = false;
    }

    // 4. Background: build full queue without blocking playback
    _resolveQueueInBackground(songs, startIndex, mySession);
  }

  // Resolves all other songs and splices them into the live playlist.
  // Checks session ID at every async boundary — if user tapped a new song,
  // this entire routine exits silently without touching the player.
  void _resolveQueueInBackground(
      List<Song> songs, int startIndex, int sessionId) async {
    try {
      // --- Songs AFTER startIndex (append) ---
      for (int i = startIndex + 1; i < songs.length; i++) {
        if (sessionId != _playSessionId) return;
        try {
          final source = await _sourceForSong(songs[i]);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            // Get current ConcatenatingAudioSource from player
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.add(source);
            }
          }
        } catch (_) {}
      }

      // --- Songs BEFORE startIndex (prepend one by one, adjust index) ---
      // We insert in reverse so final order is correct.
      //
      // FIX: _currentIndex tracks position within `_queue` (already correct,
      // set to startIndex in playQueue) and must NOT be mutated here. What
      // actually shifts is the LIVE player's ConcatenatingAudioSource index
      // (it started with just one song at player-position 0), so we track
      // that separately as `playerIndex` and use it only for the seek call
      // that keeps just_audio's currentIndexStream pointed at the right
      // (still-playing) item while songs are spliced in before it.
      int playerIndex = 0;
      for (int i = startIndex - 1; i >= 0; i--) {
        if (sessionId != _playSessionId) return;
        try {
          final source = await _sourceForSong(songs[i]);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.insert(0, source);
              playerIndex++;
              // Seek to same position in same song (player index shifted by 1)
              await _player.seek(_player.position, index: playerIndex);
            }
          }
        } catch (_) {}
      }
    } finally {
      // Only the still-active session may lower the flag — a superseded
      // session must never clear a newer session's in-progress splice.
      if (sessionId == _playSessionId) _splicingInProgress = false;
    }
  }

  // ─── SINGLE SONG (no queue context) ──────────────────────────────────────

  Future<void> playSong(Song song) async {
    _playSessionId++;
    final mySession = _playSessionId;

    _queue        = [song];
    _currentIndex = 0;
    _splicingInProgress = false; // single-song queue, no splice phase
    onQueueChanged?.call();

    await _player.stop();
    if (mySession != _playSessionId) return;

    final source = await _sourceForSong(song);
    if (mySession != _playSessionId) return;
    if (source == null) return;

    final fresh = ConcatenatingAudioSource(children: [source]);
    await _player.setAudioSource(fresh, initialIndex: 0, preload: true);
    if (mySession != _playSessionId) return;

    await _reapplySpeed();
    _updateMediaItem(song);
    await _player.play();
  }

  // ─── QUEUE MUTATIONS ──────────────────────────────────────────────────────

  Future<void> addToQueue(Song song) async {
    _queue.add(song);
    final source = await _sourceForSong(song);
    if (source == null) return;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.add(source);
  }

  Future<void> playNext(Song song) async {
    final insertIdx = _currentIndex + 1;
    _queue.insert(insertIdx, song);
    final source = await _sourceForSong(song);
    if (source == null) return;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.insert(insertIdx, source);
  }

  Future<void> removeFromQueue(int index) async {
    if (index >= _queue.length) return;
    _queue.removeAt(index);
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource && index < seq.length) {
      await seq.removeAt(index);
    }
  }

  Future<void> moveQueueItem(int from, int to) async {
    final song = _queue.removeAt(from);
    _queue.insert(to, song);
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.move(from, to);
  }

  Future<void> clearQueue() async {
    _playSessionId++; // cancel any background work
    _queue        = [];
    _currentIndex = 0;
    _splicingInProgress = false;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.clear();
    mediaItem.add(null);
  }

  // ─── GETTERS ──────────────────────────────────────────────────────────────

  List<Song> get currentQueue  => List.unmodifiable(_queue);
  Song?      get currentSong   => _queue.isNotEmpty ? _queue[_currentIndex] : null;
  int        get currentIndex  => _currentIndex;
  AudioPlayer get player       => _player;

  // ─── MEDIA ITEM ───────────────────────────────────────────────────────────

  void _updateMediaItem(Song song) => mediaItem.add(_songToMediaItem(song));

  MediaItem _songToMediaItem(Song song) => MediaItem(
        id:      song.id,
        title:   song.title,
        artist:  song.artist,
        album:   song.album,
        artUri:  song.artworkUrl.isNotEmpty ? Uri.parse(song.artworkUrl) : null,
        duration: song.duration != null ? Duration(seconds: song.duration!) : null,
      );

  // ─── PLAYBACK STATE BROADCAST ─────────────────────────────────────────────

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: {
        ProcessingState.idle:      AudioProcessingState.idle,
        ProcessingState.loading:   AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready:     AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing:          playing,
      updatePosition:   _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed:            _player.speed,
      queueIndex:       _currentIndex,
    ));
  }

  // ─── TRANSPORT CONTROLS ───────────────────────────────────────────────────

  @override Future<void> play()  => _player.play();
  @override Future<void> pause() => _player.pause();
  @override Future<void> stop()  => _player.stop();
  @override Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_currentIndex < _queue.length - 1) await _player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else if (_currentIndex > 0) {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.seek(Duration.zero, index: index);
    await _player.play();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        await _player.setLoopMode(LoopMode.off);
        break;
      case AudioServiceRepeatMode.one:
        await _player.setLoopMode(LoopMode.one);
        break;
      case AudioServiceRepeatMode.all:
        await _player.setLoopMode(LoopMode.all);
        break;
      default:
        break;
    }
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    await _player.setShuffleModeEnabled(enabled);
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  Future<void> disposeHandler() async {
    _shakeSub?.cancel();
    await _player.dispose();
  }
}
