import 'dart:io';
import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/song.dart';
import '../utils/constants.dart';
import 'api_service.dart';

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  final _playlist = ConcatenatingAudioSource(children: []);

  List<Song> _queue = [];
  int _currentIndex = 0;

  // Guards against race conditions in background resolver
  int _resolveGeneration = 0;

  AurumAudioHandler() {
    _init();
  }

  // ── Init ─────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _player.pause();
      } else {
        if (event.type == AudioInterruptionType.pause) {
          _player.play();
        }
      }
    });

    session.becomingNoisyEventStream.listen((_) => _player.pause());

    _player.playbackEventStream.listen(_broadcastState,
        onError: (Object e, StackTrace st) {
      _broadcastState(_player.playbackEvent);
    });

    _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    _player.currentIndexStream.listen((index) {
      if (index != null && index != _currentIndex && index < _queue.length) {
        _currentIndex = index;
        _updateMediaItem(_queue[index]);
        _saveLastPlayed();
      }
    });

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (_player.loopMode == LoopMode.off) {
          if (_currentIndex < _queue.length - 1) {
            skipToNext();
          }
        }
      }
    });

    // Restore last played queue on startup
    _restoreQueue();
  }

  // ── Source resolution with retry ─────────────────────────────────────────

  /// Resolves an AudioSource for a song. Retries once on failure.
  /// Returns null only if both attempts fail.
  Future<AudioSource?> _sourceForSong(Song song, {int retries = 1}) async {
    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        if (song.isLocal) {
          final file = File(song.localPath!);
          if (!await file.exists()) return null;
          return AudioSource.uri(
            Uri.file(song.localPath!),
            tag: _songToMediaItem(song),
          );
        } else {
          final url = await ApiService.resolveStreamUrl(song);
          if (url == null || url.isEmpty) continue;
          return AudioSource.uri(
            Uri.parse(url),
            tag: _songToMediaItem(song),
          );
        }
      } catch (_) {
        if (attempt < retries) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    return null;
  }

  // ── Play queue ────────────────────────────────────────────────────────────

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    final clampedIndex = startIndex.clamp(0, songs.length - 1);

    _queue = List.from(songs);
    _currentIndex = clampedIndex;

    // Resolve start song first — show error if it truly fails
    final startSource = await _sourceForSong(songs[clampedIndex]);
    if (startSource == null) {
      // Try next available song in queue
      for (int i = 0; i < songs.length; i++) {
        if (i == clampedIndex) continue;
        final fallback = await _sourceForSong(songs[i]);
        if (fallback != null) {
          _currentIndex = i;
          await _buildAndPlayPlaylist(songs, i, fallback);
          return;
        }
      }
      return; // Nothing playable
    }

    await _buildAndPlayPlaylist(songs, clampedIndex, startSource);
  }

  Future<void> _buildAndPlayPlaylist(
    List<Song> songs,
    int startIndex,
    AudioSource startSource,
  ) async {
    // Build playlist with only the start song resolved.
    // Other slots get a silent placeholder that WON'T crash just_audio —
    // we use a valid but inaudible data URI instead of a fake HTTP URL.
    final sources = <AudioSource>[];
    for (int i = 0; i < songs.length; i++) {
      if (i == startIndex) {
        sources.add(startSource);
      } else {
        // Use the real source shell (tag only) — actual URL resolved in bg
        sources.add(AudioSource.uri(
          // A 1-second silent MP3 data URI — valid, won't error
          Uri.parse(
              'https://aurum-stream.sharmashivam9109.workers.dev/api/silence'),
          tag: _songToMediaItem(songs[i]),
        ));
      }
    }

    await _playlist.clear();
    await _playlist.addAll(sources);

    try {
      await _player.setAudioSource(_playlist,
          initialIndex: startIndex, initialPosition: Duration.zero);
    } catch (_) {
      // If playlist load fails, try single song
      await _playlist.clear();
      await _playlist.add(startSource);
      await _player.setAudioSource(_playlist);
    }

    _updateMediaItem(songs[startIndex]);
    await _player.play();

    // Resolve rest of queue in background — with generation guard
    _resolveQueueInBackground(songs, startIndex);
    _saveQueueToPrefs();
  }

  void _resolveQueueInBackground(List<Song> songs, int startIndex) async {
    final generation = ++_resolveGeneration;

    // Resolve neighbours first (next, then prev, then rest)
    final order = <int>[];
    for (int delta = 1; delta < songs.length; delta++) {
      final next = startIndex + delta;
      final prev = startIndex - delta;
      if (next < songs.length) order.add(next);
      if (prev >= 0) order.add(prev);
    }

    for (final i in order) {
      // Bail out if a new queue was started
      if (_resolveGeneration != generation) return;
      if (i == startIndex) continue;

      try {
        final source = await _sourceForSong(songs[i]);
        if (source == null) continue;
        if (_resolveGeneration != generation) return;
        if (i < _playlist.length) {
          await _playlist.removeAt(i);
          await _playlist.insert(i, source);
        }
      } catch (_) {}

      // Small delay to not block audio thread
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  // ── Play single song ──────────────────────────────────────────────────────

  Future<void> playSong(Song song) async {
    _queue = [song];
    _currentIndex = 0;
    ++_resolveGeneration; // Cancel any ongoing background resolve

    final source = await _sourceForSong(song);
    if (source == null) return;

    await _playlist.clear();
    await _playlist.add(source);

    try {
      await _player.setAudioSource(_playlist);
    } catch (_) {
      return;
    }

    _updateMediaItem(song);
    await _player.play();
    _saveQueueToPrefs();
  }

  // ── Queue management ──────────────────────────────────────────────────────

  Future<void> addToQueue(Song song) async {
    _queue.add(song);
    final source = await _sourceForSong(song);
    if (source != null) await _playlist.add(source);
    _saveQueueToPrefs();
  }

  Future<void> playNext(Song song) async {
    final insertIdx = (_currentIndex + 1).clamp(0, _queue.length);
    _queue.insert(insertIdx, song);
    final source = await _sourceForSong(song);
    if (source != null) {
      if (insertIdx <= _playlist.length) {
        await _playlist.insert(insertIdx, source);
      } else {
        await _playlist.add(source);
      }
    }
    _saveQueueToPrefs();
  }

  Future<void> removeFromQueue(int index) async {
    if (index >= 0 && index < _queue.length) {
      _queue.removeAt(index);
      if (index < _playlist.length) await _playlist.removeAt(index);
      _saveQueueToPrefs();
    }
  }

  Future<void> moveQueueItem(int from, int to) async {
    if (from >= 0 &&
        from < _queue.length &&
        to >= 0 &&
        to < _queue.length) {
      final song = _queue.removeAt(from);
      _queue.insert(to, song);
      await _playlist.move(from, to);
      _saveQueueToPrefs();
    }
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _saveQueueToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson =
          jsonEncode(_queue.map((s) => s.toJson()).toList());
      await prefs.setString(AppConstants.keyQueueState, queueJson);
      await prefs.setInt(AppConstants.keyQueueIndex, _currentIndex);
    } catch (_) {}
  }

  Future<void> _saveLastPlayed() async {
    try {
      if (_queue.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          AppConstants.keyLastSong,
          jsonEncode(_queue[_currentIndex].toJson()));
      await prefs.setInt(AppConstants.keyQueueIndex, _currentIndex);
    } catch (_) {}
  }

  Future<void> _restoreQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString(AppConstants.keyQueueState);
      final savedIndex = prefs.getInt(AppConstants.keyQueueIndex) ?? 0;
      if (queueJson == null) return;

      final list = jsonDecode(queueJson) as List;
      final songs = list
          .map((j) => Song.fromJson(Map<String, dynamic>.from(j)))
          .toList();

      if (songs.isEmpty) return;
      _queue = songs;
      _currentIndex = savedIndex.clamp(0, songs.length - 1);

      // Update media item so lock screen shows last song even before play
      _updateMediaItem(songs[_currentIndex]);
    } catch (_) {}
  }

  // ── Getters ───────────────────────────────────────────────────────────────

  List<Song> get currentQueue => List.unmodifiable(_queue);
  Song? get currentSong =>
      _queue.isNotEmpty ? _queue[_currentIndex] : null;
  int get currentIndex => _currentIndex;
  AudioPlayer get player => _player;

  // ── Media item ────────────────────────────────────────────────────────────

  void _updateMediaItem(Song song) =>
      mediaItem.add(_songToMediaItem(song));

  MediaItem _songToMediaItem(Song song) => MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.artworkUrl.isNotEmpty
            ? Uri.tryParse(song.artworkUrl)
            : null,
        duration: song.duration != null
            ? Duration(seconds: song.duration!)
            : null,
        extras: {'isLocal': song.isLocal},
      );

  // ── Playback state broadcast ──────────────────────────────────────────────

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
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentIndex,
    ));
  }

  // ── BaseAudioHandler overrides ────────────────────────────────────────────

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_currentIndex < _queue.length - 1) {
      await _player.seekToNext();
    }
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
    if (index >= 0 && index < _queue.length) {
      await _player.seek(Duration.zero, index: index);
      await _player.play();
    }
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
    playbackState
        .add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> setShuffleMode(
      AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    await _player.setShuffleModeEnabled(enabled);
    playbackState
        .add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }
}
