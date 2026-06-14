import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import 'api_service.dart';

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  final _playlist = ConcatenatingAudioSource(children: []);

  List<Song> _queue = [];
  int _currentIndex = 0;

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // Audio session (audio focus, call handling)
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

    session.becomingNoisyEventStream.listen((_) {
      // Headphones unplugged — pause
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

  }

  // ── Resolve AudioSource for any song (online or local) ──────────────────

  Future<AudioSource?> _sourceForSong(Song song) async {
    if (song.isLocal) {
      // Local song — localPath holds a content:// URI (MediaStore) or file:// path.
      // We use Uri.parse() directly so both schemes work on all Android versions.
      // File() + Uri.file() breaks on Android 10+ for content:// URIs.
      final path = song.localPath!;
      final uri = path.startsWith('content://') || path.startsWith('file://')
          ? Uri.parse(path)
          : Uri.file(path); // fallback for bare paths
      return AudioSource.uri(uri, tag: _songToMediaItem(song));
    } else {
      // Online song — resolve stream URL from backend
      final url = await ApiService.resolveStreamUrl(song);
      if (url == null) return null;
      return AudioSource.uri(
        Uri.parse(url),
        tag: _songToMediaItem(song),
      );
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
        // Placeholder — replaced by background resolver
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

  /// Clears queue and resets state — used when user swipe-dismisses mini player.
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
        duration:
            song.duration != null ? Duration(seconds: song.duration!) : null,
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
}
