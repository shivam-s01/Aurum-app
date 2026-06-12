import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import 'api_service.dart';

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  List<Song> _queue = [];
  int _currentIndex = 0;
  bool _isResolvingNext = false;

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
        if (event.type == AudioInterruptionType.pause) {
          ApiService.onNetworkRestored();
          _player.play();
        }
      }
    });

    session.becomingNoisyEventStream.listen((_) => _player.pause());

    _player.playbackEventStream.listen(_broadcastState);

    _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    // Smart prefetch: resolve next track's stream URL at 80% of current track
    _player.positionStream.listen((pos) {
      final dur = _player.duration;
      if (dur == null || dur.inSeconds < 5) return;
      final pct = pos.inMilliseconds / dur.inMilliseconds;
      if (pct >= 0.80 && _currentIndex < _queue.length - 1) {
        ApiService.prefetchNext(_queue[_currentIndex + 1]);
      }
    });

    _player.playerStateStream.listen((state) async {
      if (state.processingState == ProcessingState.completed && !_isResolvingNext) {
        _isResolvingNext = true;
        await skipToNext();
        _isResolvingNext = false;
      }
    });
  }

  Future<AudioSource?> _sourceForSong(Song song) async {
    if (song.isLocal) {
      final file = File(song.localPath!);
      if (!await file.exists()) return null;
      return AudioSource.uri(Uri.file(song.localPath!), tag: _songToMediaItem(song));
    } else {
      final url = await ApiService.resolveStreamUrl(song);
      if (url == null || url.isEmpty) return null;
      return AudioSource.uri(Uri.parse(url), tag: _songToMediaItem(song));
    }
  }

  Future<void> playSong(Song song) async {
    _queue = [song];
    _currentIndex = 0;
    final source = await _sourceForSong(song);
    if (source == null) return;
    _updateMediaItem(song);
    await _player.setAudioSource(source);
    await _player.play();
  }

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    _queue = List.from(songs);
    _currentIndex = startIndex;
    final source = await _sourceForSong(songs[startIndex]);
    if (source == null) return;
    _updateMediaItem(songs[startIndex]);
    await _player.setAudioSource(source);
    await _player.play();
  }

  @override
  Future<void> skipToNext() async {
    if (_currentIndex < _queue.length - 1) {
      _currentIndex++;
      final source = await _sourceForSong(_queue[_currentIndex]);
      if (source == null) {
        await skipToNext();
        return;
      }
      _updateMediaItem(_queue[_currentIndex]);
      await _player.setAudioSource(source);
      await _player.play();
    }
    _broadcastStateManual();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_currentIndex > 0) {
      _currentIndex--;
      final source = await _sourceForSong(_queue[_currentIndex]);
      if (source == null) return;
      _updateMediaItem(_queue[_currentIndex]);
      await _player.setAudioSource(source);
      await _player.play();
    }
    _broadcastStateManual();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    final source = await _sourceForSong(_queue[index]);
    if (source == null) return;
    _updateMediaItem(_queue[index]);
    await _player.setAudioSource(source);
    await _player.play();
    _broadcastStateManual();
  }

  Future<void> addToQueue(Song song) async {
    _queue.add(song);
    _broadcastStateManual();
  }

  Future<void> playNext(Song song) async {
    _queue.insert(_currentIndex + 1, song);
    _broadcastStateManual();
  }

  Future<void> removeFromQueue(int index) async {
    if (index >= 0 && index < _queue.length) {
      _queue.removeAt(index);
      if (index < _currentIndex) _currentIndex--;
      _broadcastStateManual();
    }
  }

  Future<void> moveQueueItem(int from, int to) async {
    if (from < 0 || from >= _queue.length || to < 0 || to >= _queue.length) return;
    final song = _queue.removeAt(from);
    _queue.insert(to, song);
    if (_currentIndex == from) {
      _currentIndex = to;
    } else if (from < _currentIndex && to >= _currentIndex) {
      _currentIndex--;
    } else if (from > _currentIndex && to <= _currentIndex) {
      _currentIndex++;
    }
    _broadcastStateManual();
  }

  List<Song> get currentQueue => List.unmodifiable(_queue);
  Song? get currentSong => _queue.isNotEmpty ? _queue[_currentIndex] : null;
  int get currentIndex => _currentIndex;
  AudioPlayer get player => _player;

  void _updateMediaItem(Song song) => mediaItem.add(_songToMediaItem(song));

  MediaItem _songToMediaItem(Song song) => MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.artworkUrl.isNotEmpty ? Uri.parse(song.artworkUrl) : null,
        duration: song.duration != null ? Duration(seconds: song.duration!) : null,
      );

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

  void _broadcastStateManual() {
    playbackState.add(playbackState.value.copyWith(queueIndex: _currentIndex));
  }

  @override Future<void> play() async {
    // Refresh stream URL if it may have expired (e.g. app backgrounded for hours)
    final song = currentSong;
    if (song != null && !song.isLocal) {
      final cached = ApiService.resolveStreamUrl(song); // uses cache, non-blocking
      unawaited(cached); // fire-and-forget; just warm the cache
    }
    return _player.play();
  }
  @override Future<void> pause() => _player.pause();
  @override Future<void> stop()  => _player.stop();
  @override Future<void> seek(Duration position) => _player.seek(position);

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
