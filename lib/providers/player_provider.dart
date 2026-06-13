import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../services/audio_handler.dart';
import '../services/api_service.dart';

class PlayerProvider extends ChangeNotifier {
  final AurumAudioHandler _handler;

  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  LoopMode _loopMode = LoopMode.off;
  bool _shuffle = false;
  bool _showFullPlayer = false;

  PlayerProvider(this._handler) {
    _handler.player.playingStream.listen((playing) {
      _isPlaying = playing;
      notifyListeners();
    });
    _handler.player.positionStream.listen((pos) {
      _position = pos;
      notifyListeners();
    });
    _handler.player.durationStream.listen((dur) {
      if (dur != null) {
        _duration = dur;
        notifyListeners();
      }
    });
    _handler.player.bufferedPositionStream.listen((buf) {
      _buffered = buf;
      notifyListeners();
    });
    _handler.player.processingStateStream.listen((state) {
      _isLoading = state == ProcessingState.loading || state == ProcessingState.buffering;
      notifyListeners();
    });
    _handler.player.loopModeStream.listen((mode) {
      _loopMode = mode;
      notifyListeners();
    });
    _handler.player.shuffleModeEnabledStream.listen((s) {
      _shuffle = s;
      notifyListeners();
    });
  }

  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get buffered => _buffered;
  LoopMode get loopMode => _loopMode;
  bool get shuffle => _shuffle;
  bool get showFullPlayer => _showFullPlayer;
  Song? get currentSong => _handler.currentSong;
  List<Song> get queue => _handler.currentQueue;
  int get currentIndex => _handler.currentIndex;
  bool get hasSong => _handler.currentSong != null;

  double get progress {
    if (_duration.inMilliseconds == 0) return 0.0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  String get positionString => _formatDuration(_position);
  String get durationString => _formatDuration(_duration);

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> playSong(Song song, {List<Song>? queue, int? index}) async {
    if (queue != null && index != null) {
      await _handler.playQueue(queue, index);
    } else {
      await _handler.playSong(song);
    }
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (_isPlaying) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
  }

  Future<void> seek(double ratio) async {
    final pos = Duration(milliseconds: (_duration.inMilliseconds * ratio).round());
    await _handler.seek(pos);
  }

  Future<void> seekTo(Duration pos) => _handler.seek(pos);

  Future<void> skipNext() => _handler.skipToNext();
  Future<void> skipPrev() => _handler.skipToPrevious();

  Future<void> addToQueue(Song song) async {
    await _handler.addToQueue(song);
    notifyListeners();
  }

  Future<void> playNext(Song song) async {
    await _handler.playNext(song);
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    await _handler.removeFromQueue(index);
    notifyListeners();
  }

  Future<void> moveQueueItem(int from, int to) async {
    await _handler.moveQueueItem(from, to);
    notifyListeners();
  }

  Future<void> skipToIndex(int index) async {
    await _handler.skipToQueueItem(index);
    notifyListeners();
  }

  Future<void> toggleLoop() async {
    final next = _loopMode == LoopMode.off
        ? LoopMode.all
        : _loopMode == LoopMode.all
            ? LoopMode.one
            : LoopMode.off;
    await _handler.setRepeatMode(
      next == LoopMode.off
          ? AudioServiceRepeatMode.none
          : next == LoopMode.one
              ? AudioServiceRepeatMode.one
              : AudioServiceRepeatMode.all,
    );
  }

  Future<void> toggleShuffle() async {
    await _handler.setShuffleMode(
      _shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all,
    );
  }

  void openFullPlayer() {
    _showFullPlayer = true;
    notifyListeners();
  }

  Future<void> pause() async {
    await _handler.pause();
  }

  void closeFullPlayer() {
    _showFullPlayer = false;
    notifyListeners();
  }

  Future<String?> fetchLyrics() async {
    final song = currentSong;
    if (song == null) return null;
    return ApiService.fetchLyrics(song);
  }
}

// Note: append above the closing brace manually, or use the method below
