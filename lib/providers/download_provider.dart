import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/download_item.dart';
import '../services/notification_service.dart';
import '../services/api_service.dart';
import '../services/native_engine_bridge.dart';

/// Manages downloading songs for offline playback.
///
/// - Persists state in Hive (`aurum_downloads`) so the Downloads screen
///   survives app restarts.
/// - Uses Dio for the actual file transfer with live progress.
/// - Drives NotificationService for a Spotify-style progress notification
///   that updates in place, then flips to "Download complete".
/// - Stores files in the app's own sandbox directory (no storage
///   permission needed, scoped automatically by Android, cleaned up on
///   uninstall).
class DownloadProvider extends ChangeNotifier {
  static const _boxName = 'aurum_downloads';

  // FIX (2026-07-07) — see the resolveForDownload call further below:
  // injected so downloads can use the same native-first YouTube resolver
  // (YoutubeInnertube/NewPipeExtractor via HybridStreamResolver) that live
  // playback already uses, instead of only the old Worker-only chain.
  final NativeAudioEngine _engine;
  DownloadProvider(this._engine);

  late Box<Map> _box;
  final Map<String, DownloadItem> _items = {}; // keyed by song.id
  final Map<String, CancelToken> _cancelTokens = {};

  bool _initialized = false;

  List<DownloadItem> get items =>
      _items.values.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  List<DownloadItem> get completed =>
      items.where((d) => d.status == DownloadStatus.completed).toList();

  List<DownloadItem> get inProgress =>
      items.where((d) => d.isDownloading).toList();

  bool isDownloaded(String songId) =>
      _items[songId]?.status == DownloadStatus.completed;

  bool isDownloading(String songId) => _items[songId]?.isDownloading ?? false;

  DownloadItem? statusOf(String songId) => _items[songId];

  /// Returns the local file Song (with localPath set) if this song has
  /// been downloaded — used to play fully offline.
  Song? offlineSongFor(String songId) {
    final item = _items[songId];
    if (item != null && item.isCompleted && item.localPath != null) {
      return item.song.copyWith(localPath: item.localPath);
    }
    return null;
  }

  Future<void> init() async {
    if (_initialized) return;
    _box = await Hive.openBox<Map>(_boxName);

    for (final raw in _box.values) {
      try {
        final item = DownloadItem.fromJson(Map<String, dynamic>.from(raw));
        // Any download that was mid-flight when the app died is now stale.
        final fixed = item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.queued
            ? item.copyWith(status: DownloadStatus.failed)
            : item;
        _items[fixed.song.id] = fixed;
      } catch (_) {
        // skip corrupt entry
      }
    }

    await NotificationService.instance.init();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist(DownloadItem item) async {
    _items[item.song.id] = item;
    await _box.put(item.song.id, item.toJson());
    notifyListeners();
  }

  Future<Directory> _downloadsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeFileName(Song song) {
    final safe = '${song.title}_${song.artist}'
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return '${safe.isEmpty ? song.id : safe}.mp3';
  }

  /// Starts (or resumes) downloading a song. Safe to call multiple times —
  /// no-ops if already downloaded or currently downloading.
  ///
  /// Returns true if the download actually started, false if it couldn't
  /// (e.g. no stream URL could be resolved) — callers use this to show
  /// the right feedback to the user.
  Future<bool> download(Song song) async {
    if (isDownloaded(song.id) || isDownloading(song.id)) return true;
    if (song.isLocal) return false;

    // ── WiFi-only check ────────────────────────────────────────────────────
    final prefs = await SharedPreferences.getInstance();
    final wifiOnly = prefs.getBool('download_wifi_only') ?? true;
    if (wifiOnly) {
      final result = await Connectivity().checkConnectivity();
      final onWifi = result.contains(ConnectivityResult.wifi);
      if (!onWifi) return false; // caller should show "WiFi only" snackbar
    }

    // ── Resolve quality order for this download ────────────────────────────
    final rawQuality = prefs.getString('download_quality') ?? '320kbps';
    // Build a priority list that starts with the user's chosen quality and
    // falls back gracefully, so we always get something even if that exact
    // quality isn't available from the API.
    final List<String> qualityOrder;
    switch (rawQuality) {
      case '96kbps':
        qualityOrder = const ['96kbps', '48kbps', '12kbps'];
        break;
      case '128kbps':
        qualityOrder = const ['160kbps', '96kbps', '48kbps', '12kbps'];
        break;
      case '320kbps':
      default:
        qualityOrder = const ['320kbps', '160kbps', '96kbps', '48kbps', '12kbps'];
    }

    // Show "queued" immediately so the UI reacts instantly, even while we
    // resolve the actual stream URL (YouTube songs don't carry one upfront).
    await _persist(DownloadItem(song: song, status: DownloadStatus.queued));
    await NotificationService.instance.showProgress(
      songId: song.id,
      title: song.title,
      percent: 0,
    );

    String? url = song.streamUrl;
    if (url == null || url.isEmpty || !url.startsWith('http')) {
      try {
        // FIX (2026-07-07) — "YouTube downloads fail / stuck resolving":
        // ApiService.resolveDownloadUrl() falls through to
        // ApiService.resolveStreamUrl() for youtube-source songs, which is
        // the OLD Worker-only resolve chain (Cloudflare Worker's
        // SABR-gated YouTube clients + Piped fallback). Live playback
        // stopped depending on that chain once NewPipeExtractor was
        // bumped to v0.26.3 and playback moved to a native-first resolver
        // (HybridStreamResolver: YoutubeInnertube first, Worker/Dart only
        // as fallback) — but downloads never got that benefit, since
        // nothing about the download path went through the native engine
        // at all. For youtube-source songs, try the native-first resolver
        // (same one playback uses) before falling back to the old
        // Dart-only chain, so downloads get the same reliability
        // improvement playback already has.
        if (song.source == SongSource.youtube) {
          url = await _engine.resolveForDownload(song);
        }
        url ??= await ApiService.resolveDownloadUrl(song, qualityOrder: qualityOrder);
      } catch (_) {
        url = null;
      }
    }

    if (url == null || url.isEmpty) {
      await _persist(_items[song.id]!.copyWith(status: DownloadStatus.failed));
      await NotificationService.instance.showFailed(
        songId: song.id,
        title: song.title,
      );
      return false;
    }

    final cancelToken = CancelToken();
    _cancelTokens[song.id] = cancelToken;

    // FIX (2026-07-02): declared outside the try block so the catch clause
    // below can reach it too — needed to clean up the orphaned `.part` file
    // on cancel/failure (see catch block). Previously this leaked a
    // half-downloaded file on disk every time a download was cancelled or
    // failed mid-transfer, since nothing ever deleted it afterward.
    String? tempPath;

    try {
      final dir = await _downloadsDir();
      final filePath = '${dir.path}/${_safeFileName(song)}';
      tempPath = '$filePath.part';

      await _persist(
        _items[song.id]!.copyWith(status: DownloadStatus.downloading),
      );

      int lastNotifiedPercent = -1;

      await Dio().download(
        url,
        tempPath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) async {
          if (total <= 0) return;
          final progress = received / total;
          final current = _items[song.id];
          if (current == null) return;

          await _persist(current.copyWith(progress: progress));

          final percent = (progress * 100).round();
          // Only push a notification update every whole percent to avoid spam.
          if (percent != lastNotifiedPercent) {
            lastNotifiedPercent = percent;
            await NotificationService.instance.showProgress(
              songId: song.id,
              title: song.title,
              percent: percent,
            );
          }
        },
      );

      // Move temp -> final so a half-written file is never mistaken as done.
      final tempFile = File(tempPath);
      final finalFile = File(filePath);
      if (await finalFile.exists()) await finalFile.delete();
      await tempFile.rename(filePath);

      final size = await finalFile.length();

      await _persist(_items[song.id]!.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        localPath: filePath,
        fileSizeBytes: size,
      ));

      await NotificationService.instance.showCompleted(
        songId: song.id,
        title: song.title,
      );
      return true;
    } catch (e) {
      // FIX (2026-07-02): clean up the orphaned partial file left behind on
      // cancel/failure — previously nothing deleted this, so every
      // cancelled or failed download quietly left a `.part` file on disk
      // forever, wasting storage over time.
      if (tempPath != null) {
        try {
          final leftover = File(tempPath);
          if (await leftover.exists()) await leftover.delete();
        } catch (_) {}
      }

      if (cancelToken.isCancelled) {
        await _persist(_items[song.id]!.copyWith(status: DownloadStatus.cancelled));
        await NotificationService.instance.cancelProgress(song.id);
        return false;
      } else {
        await _persist(_items[song.id]!.copyWith(status: DownloadStatus.failed));
        await NotificationService.instance.showFailed(
          songId: song.id,
          title: song.title,
        );
        return false;
      }
    } finally {
      _cancelTokens.remove(song.id);
    }
  }

  Future<void> cancelDownload(String songId) async {
    _cancelTokens[songId]?.cancel();
  }

  Future<void> retry(Song song) async {
    _items.remove(song.id);
    await _box.delete(song.id);
    await download(song);
  }

  Future<void> deleteDownload(String songId) async {
    final item = _items[songId];
    if (item?.localPath != null) {
      final f = File(item!.localPath!);
      if (await f.exists()) await f.delete();
    }
    _items.remove(songId);
    await _box.delete(songId);
    await NotificationService.instance.cancelProgress(songId);
    notifyListeners();
  }

  /// Total space used by all completed downloads, in bytes.
  int get totalBytesUsed => completed.fold(0, (sum, d) => sum + (d.fileSizeBytes ?? 0));
}
