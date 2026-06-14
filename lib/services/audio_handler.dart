import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'api_service.dart';

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player   = AudioPlayer();
  final _playlist = ConcatenatingAudioSource(children: []);

  List<Song> _queue        = [];
  int        _currentIndex = 0;

  // Cancellation token — each new playQueue/playSong call gets a fresh ID.
  // Background resolvers check this before touching the playlist.
  int _playSessionId = 0;

  // Prevent concurrent playQueue calls from racing each other.
  bool _isLoadingNewSong = false;

  StreamSubscription<AccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime.now();
  static const double _shakeThreshold = 15.0;

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _player.pause();
      } else {
        if (event.type == AudioInterruptionType.pause) _player.play();
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
      if (index != null && index != _currentIndex && index < _queue.length) {
        _currentIndex = index;
        _updateMediaItem(_queue[index]);
      }
    });

    await _applySettings();
  }

  Future<void> _applySettings() async {
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

    try {
      // 1. Hard stop — old song dies immediately, no bleed-through
      await _player.stop();

      // Check if superseded by an even newer tap
      if (mySession != _playSessionId) return;

      _queue        = List<Song>.from(songs);
      _currentIndex = 0; // always 0 in fresh playlist; we adjust after prepend

      // 2. Resolve clicked song
      final startSource = await _sourceForSong(songs[startIndex]);
      if (mySession != _playSessionId) return; // superseded
      if (startSource == null) return;

      // 3. Fresh single-song playlist — no placeholders, no auto-skip
      final fresh = ConcatenatingAudioSource(children: [startSource]);
      await _player.setAudioSource(fresh, initialIndex: 0, preload: true);
      if (mySession != _playSessionId) return;

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
    // --- Songs AFTER startIndex (append) ---
    for (int i = startIndex + 1; i < songs.length; i++) {
      if (sessionId != _playSessionId) return;
      try {
        final source = await _sourceForSong(songs[i]);
        if (sessionId != _playSessionId) return;
        if (source != null) {
          await _player.sequence?.last; // wait for player to be stable
          // Get current ConcatenatingAudioSource from player
          final seq = _player.audioSource;
          if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
            await seq.add(source);
          }
        }
      } catch (_) {}
    }

    // --- Songs BEFORE startIndex (prepend one by one, adjust index) ---
    // We insert in reverse so final order is correct
    for (int i = startIndex - 1; i >= 0; i--) {
      if (sessionId != _playSessionId) return;
      try {
        final source = await _sourceForSong(songs[i]);
        if (sessionId != _playSessionId) return;
        if (source != null) {
          final seq = _player.audioSource;
          if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
            await seq.insert(0, source);
            _currentIndex++;
            // Seek to same position in same song (index shifted by 1)
            await _player.seek(_player.position, index: _currentIndex);
          }
        }
      } catch (_) {}
    }
  }

  // ─── SINGLE SONG (no queue context) ──────────────────────────────────────

  Future<void> playSong(Song song) async {
    _playSessionId++;
    final mySession = _playSessionId;

    await _player.stop();
    if (mySession != _playSessionId) return;

    _queue        = [song];
    _currentIndex = 0;

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
