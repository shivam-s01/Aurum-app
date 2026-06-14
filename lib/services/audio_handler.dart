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
  final _player = AudioPlayer();
  final _playlist = ConcatenatingAudioSource(children: []);

  List<Song> _queue = [];
  int _currentIndex = 0;

  // Settings
  StreamSubscription<AccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime.now();
  static const _shakeThreshold = 15.0; // m/s²

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // Audio session (handles call interruptions automatically)
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // Pause on call — audio_session handles this natively
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _player.pause();
      } else {
        if (event.type == AudioInterruptionType.pause) {
          _player.play();
        }
      }
    });

    session.becomingNoisyEventStream.listen((_) {
      _player.pause();
    });

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

    // Apply saved settings on startup
    await _applySettings();
  }

  // ── Apply all settings from SharedPrefs ─────────────────────────────────

  Future<void> _applySettings() async {
    final p = await SharedPreferences.getInstance();

    // Playback speed
    final speed = p.getDouble('playback_speed') ?? 1.0;
    await _player.setSpeed(speed);

    // Gapless — just_audio handles gapless by default with ConcatenatingAudioSource
    // We just ensure no gap by not stopping between tracks (already the case)

    // Shake to skip
    final shakeEnabled = p.getBool('shake_to_skip') ?? false;
    _setShakeToSkip(shakeEnabled);
  }

  // ── Shake to Skip ────────────────────────────────────────────────────────

  void _setShakeToSkip(bool enabled) {
    _shakeSub?.cancel();
    _shakeSub = null;
    if (!enabled) return;

    _shakeSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      final now = DateTime.now();
      if (magnitude > _shakeThreshold &&
          now.difference(_lastShake).inMilliseconds > 1000) {
        _lastShake = now;
        skipToNext();
      }
    });
  }

  /// Call this from settings when user toggles shake/speed
  Future<void> reloadSettings() async {
    await _applySettings();
  }

  // ── Stop on task removed (swipe from recents) ────────────────────────────

  @override
  Future<void> onTaskRemoved() async {
    final p = await SharedPreferences.getInstance();
    final stopOnSwipe = p.getBool('stop_on_swipe') ?? false;
    if (stopOnSwipe) {
      await stop();
      await clearQueue();
    }
  }

  // ── Resolve AudioSource ──────────────────────────────────────────────────

  Future<AudioSource?> _sourceForSong(Song song) async {
    if (song.isLocal) {
      final path = song.localPath!;
      final uri = path.startsWith('content://') || path.startsWith('file://')
          ? Uri.parse(path)
          : Uri.file(path);
      return AudioSource.uri(uri, tag: _songToMediaItem(song));
    } else {
      // Data saver — force low quality
      final p = await SharedPreferences.getInstance();
      final dataSaver = p.getBool('data_saver') ?? false;
      final quality = dataSaver ? 'low' : (p.getString('stream_quality') ?? 'auto');

      final url = await ApiService.resolveStreamUrl(song);
      if (url == null) return null;
      return AudioSource.uri(Uri.parse(url), tag: _songToMediaItem(song));
    }
  }

  // ── Play queue ───────────────────────────────────────────────────────────

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    _queue = songs;
    _currentIndex = startIndex;

    final startSource = await _sourceForSong(songs[startIndex]);
    if (startSource == null) return;

    await _playlist.clear();

    final sources = <AudioSource>[];
    for (int i = 0; i < songs.length; i++) {
      if (i == startIndex) {
        sources.add(startSource);
      } else {
        sources.add(AudioSource.uri(
          Uri.parse('https://example.com/placeholder.mp3'),
          tag: _songToMediaItem(songs[i]),
        ));
      }
    }

    await _playlist.addAll(sources);

    try {
      await _player.setAudioSource(_playlist, initialIndex: startIndex);
    } catch (_) {
      await _player.setAudioSource(_playlist, initialIndex: 0);
    }

    // Re-apply speed after new source set
    final p = await SharedPreferences.getInstance();
    await _player.setSpeed(p.getDouble('playback_speed') ?? 1.0);

    _updateMediaItem(songs[startIndex]);
    await _player.play();
    _resolveQueueInBackground(songs, startIndex);
  }

  void _resolveQueueInBackground(List<Song> songs, int startIndex) async {
    for (int i = 0; i < songs.length; i++) {
      if (i == startIndex) continue;
      try {
        final source = await _sourceForSong(songs[i]);
        if (source != null && i < _playlist.length) {
          await _playlist.removeAt(i);
          await _playlist.insert(i, source);
        }
      } catch (_) {}
    }
  }

  // ── Play single song ─────────────────────────────────────────────────────

  Future<void> playSong(Song song) async {
    _queue = [song];
    _currentIndex = 0;

    final source = await _sourceForSong(song);
    if (source == null) return;

    await _playlist.clear();
    await _playlist.add(source);
    await _player.setAudioSource(_playlist);

    final p = await SharedPreferences.getInstance();
    await _player.setSpeed(p.getDouble('playback_speed') ?? 1.0);

    _updateMediaItem(song);
    await _player.play();
  }

  // ── Queue management ─────────────────────────────────────────────────────

  Future<void> addToQueue(Song song) async {
    _queue.add(song);
    final source = await _sourceForSong(song);
    if (source != null) await _playlist.add(source);
  }

  Future<void> playNext(Song song) async {
    final insertIdx = _currentIndex + 1;
    _queue.insert(insertIdx, song);
    final source = await _sourceForSong(song);
    if (source != null) await _playlist.insert(insertIdx, source);
  }

  Future<void> removeFromQueue(int index) async {
    if (index < _queue.length) {
      _queue.removeAt(index);
      await _playlist.removeAt(index);
    }
  }

  Future<void> moveQueueItem(int from, int to) async {
    final song = _queue.removeAt(from);
    _queue.insert(to, song);
    await _playlist.move(from, to);
  }

  // ── Getters ──────────────────────────────────────────────────────────────

  List<Song> get currentQueue => List.unmodifiable(_queue);
  Song? get currentSong => _queue.isNotEmpty ? _queue[_currentIndex] : null;
  int get currentIndex => _currentIndex;
  AudioPlayer get player => _player;

  Future<void> clearQueue() async {
    _queue = [];
    _currentIndex = 0;
    await _playlist.clear();
    mediaItem.add(null);
  }

  // ── Media item ───────────────────────────────────────────────────────────

  void _updateMediaItem(Song song) => mediaItem.add(_songToMediaItem(song));

  MediaItem _songToMediaItem(Song song) => MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.artworkUrl.isNotEmpty ? Uri.parse(song.artworkUrl) : null,
        duration: song.duration != null ? Duration(seconds: song.duration!) : null,
      );

  // ── Playback state ───────────────────────────────────────────────────────

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
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentIndex,
    ));
  }

  // ── BaseAudioHandler overrides ───────────────────────────────────────────

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

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'reloadSettings') await reloadSettings();
  }

  @override
  Future<void> onNotificationDeleted() async {
    await stop();
  }

  // ── Cleanup ──────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    _shakeSub?.cancel();
    await _player.dispose();
  }
}
