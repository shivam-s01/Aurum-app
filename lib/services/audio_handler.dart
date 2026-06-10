import 'dart:io';
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

    _player.playbackEventStream.listen(_broadcastState, onError: (e) {});

    _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    _player.currentIndexStream.listen((index) {
      if (index != null && index < _queue.length && index != _currentIndex) {
        _currentIndex = index;
        _updateMediaItem(_queue[index]);
      }
    });

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        skipToNext();
      }
    });

    _player.playingStream.listen((_) => _broadcastState(null));
  }

  Future<AudioSource?> _sourceForSong(Song song) async {
    try {
      if (song.isLocal) {
        return AudioSource.uri(Uri.file(song.localPath!), tag: _songToMediaItem(song));
      }
      final url = await ApiService.resolveStreamUrl(song);
      if (url == null) return null;
      return AudioSource.uri(Uri.parse(url), tag: _songToMediaItem(song));
    } catch (_) {
      return null;
    }
  }

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    _queue = songs;
    _currentIndex = startIndex;

    final startSource = await _sourceForSong(songs[startIndex]);
    if (startSource == null) return;

    await _playlist.clear();
    await _playlist.add(startSource);

    try {
      await _player.setAudioSource(_playlist, initialIndex: 0);
    } catch (_) {
      return;
    }

    _updateMediaItem(songs[startIndex]);
    await _player.play();

    // Resolve rest of queue in background
    _resolveQueueInBackground(songs, startIndex);
  }

  void _resolveQueueInBackground(List<Song> songs, int startIndex) async {
    // Add songs before startIndex
    for (int i = startIndex - 1; i >= 0; i--) {
      try {
        final source = await _sourceForSong(songs[i]);
        if (source != null) {
          await _playlist.insert(0, source);
          _currentIndex = _player.currentIndex ?? 0;
        }
      } catch (_) {}
    }
    // Add songs after startIndex
    for (int i = startIndex + 1; i < songs.length; i++) {
      try {
        final source = await _sourceForSong(songs[i]);
        if (source != null) {
          await _playlist.add(source);
        }
      } catch (_) {}
    }
  }

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

  Future<void> addToQueue(Song song) async {
    _queue.add(song);
    final source = await _sourceForSong(song);
    if (source != null) await _playlist.add(source);
  }

  Future<void> playNext(Song song) async {
    final idx = _currentIndex + 1;
    _queue.insert(idx, song);
    final source = await _sourceForSong(song);
    if (source != null) await _playlist.insert(idx, source);
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

  List<Song> get currentQueue => List.unmodifiable(_queue);
  Song? get currentSong => _queue.isNotEmpty ? _queue[_currentIndex] : null;
  int get currentIndex => _currentIndex;
  AudioPlayer get player => _player;

  void _updateMediaItem(Song song) => mediaItem.add(_songToMediaItem(song));

  MediaItem _songToMediaItem(Song song) => MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album.isNotEmpty ? song.album : song.artist,
        artUri: song.artworkUrl.isNotEmpty ? Uri.parse(song.artworkUrl) : null,
        duration: song.duration != null ? Duration(seconds: song.duration!) : null,
        displayTitle: song.title,
        displaySubtitle: song.artist,
      );

  void _broadcastState(PlaybackEvent? event) {
    final playing = _player.playing;
    final processingState = {
      ProcessingState.idle:      AudioProcessingState.idle,
      ProcessingState.loading:   AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready:     AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[_player.processingState] ?? AudioProcessingState.idle;

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentIndex,
    ));
  }

  @override Future<void> play()  => _player.play();
  @override Future<void> pause() => _player.pause();
  @override Future<void> stop()  async {
    await _player.stop();
    _broadcastState(null);
  }
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
      case AudioServiceRepeatMode.none: await _player.setLoopMode(LoopMode.off); break;
      case AudioServiceRepeatMode.one:  await _player.setLoopMode(LoopMode.one); break;
      case AudioServiceRepeatMode.all:  await _player.setLoopMode(LoopMode.all); break;
      default: break;
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
