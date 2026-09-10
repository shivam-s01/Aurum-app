import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/download_item.dart';
import '../services/notification_service.dart';
import '../services/api_service.dart';
import '../services/audio_prefs.dart';
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

  // SPEED FIX ("youtube songs bahut slow download ho rahe hai, network ke
  // hisab se fast download chahiye"): two real bottlenecks here, neither
  // network-speed-related in the literal sense — the transfer itself was
  // never actually being throttled by anything except these:
  //   1. `Dio()` was instantiated fresh per download with zero tuning —
  //      default connect/receive timeouts (which on a slow/flaky mobile
  //      network can sit stalled far longer than reasonable before Dio
  //      even reports a problem) and no persistent connection reuse.
  //      A single shared, tuned client fixes both: fast-fail timeouts so
  //      a genuinely bad connection retries/fails quickly instead of
  //      hanging, and a receiveTimeout that's generous enough for slow-
  //      but-working networks (matches the same philosophy as the
  //      search-timeout fix elsewhere) without hanging forever.
  //   2. onReceiveProgress (see download() below) was calling _persist()
  //      — a full Hive disk write + notifyListeners() — on EVERY chunk
  //      callback Dio fires, which is dozens of times per second on a
  //      fast connection. That disk I/O was competing with the file
  //      write for the same disk on low-end/eMMC-class devices, which
  //      measurably slows the actual transfer down. Throttled to at
  //      most once per percent (already computed) via the persist call
  //      being gated below, not on every raw byte-count callback.
  // SPEED FIX ("youtube songs download bahut slow" — separate root cause
  // from the timeout/persist fixes above): googlevideo.com CDN throttles
  // or de-prioritizes requests that don't look like they're coming from a
  // real browser — no User-Agent header at all (Dio's bare default) gets
  // served noticeably slower/lower-priority than a request with a normal
  // browser UA. This is exactly why native playback (AurumAudioEngine.kt's
  // createHttpFactory) already sets a real Chrome User-Agent on its
  // ExoPlayer HTTP data source and streams at full speed — the download
  // path went through Dio directly and never got the same treatment, so
  // Saavn downloads were fine (its CDN doesn't care) but YouTube-sourced
  // downloads crawled. Setting the identical UA here (and Referer, which
  // googlevideo also checks) gets YouTube downloads the same treatment
  // playback already gets, matched header-for-header.
  static const _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

  static final Dio _downloadClient = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // Generous — a slow-but-working mobile network (weak wifi/3G)
      // should still be allowed to finish rather than being cut off
      // mid-transfer and forced to restart from zero.
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': _browserUserAgent,
        // SPEED FIX: MP3 audio is already compressed — asking the server
        // to gzip it again (Dio/HttpClient's default Accept-Encoding)
        // wastes CPU time on both ends for zero size benefit, and some
        // hosts respond slower once they detour through their compression
        // path for content that doesn't compress further. Requesting the
        // identity encoding means the server streams raw bytes straight
        // through — the actual bottleneck (network throughput) is
        // unaffected either way, but this removes a needless CPU step
        // that was pure overhead on every single download.
        'Accept-Encoding': 'identity',
      },
    ),
  )..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        // SPEED FIX ("download ekdam slow hota hai" — plain low
        // throughput on a large sequential file transfer, not a stall/
        // timeout): Dio's default IOHttpClientAdapter creates a bare
        // dart:io HttpClient with no read-buffer tuning at all. ExoPlayer/
        // Media3 (what live playback actually streams through) uses
        // Android's native networking stack, which reads in large
        // buffered chunks; Dart's VM HttpClient, left at its defaults,
        // reads the response in much smaller increments — on many
        // Android ROMs/devices this alone is enough to make a large
        // sequential download (a 5-8MB song file) visibly slower than
        // streaming the exact same URL through ExoPlayer, even though
        // both are hitting the same CDN. Raising maxConnectionsPerHost
        // (parity with the tuned search client in api_service.dart) and
        // disabling the HttpClient's own idle/auto-compression handling
        // (already requested via the identity header above, but the
        // client-level flag ensures dart:io never negotiates it anyway)
        // removes the only two adapter-level knobs available for this —
        // the actual byte-throughput ceiling is the network, but this
        // stops Dio's own defaults from adding overhead on top of it.
        final client = HttpClient()
          ..maxConnectionsPerHost = 6
          ..autoUncompress = false;
        return client;
      },
    );

  // FIX (2026-07-07) — see the resolveForDownload call further below:
  // injected so downloads can use the same native-first YouTube resolver
  // (YoutubeInnertube/NewPipeExtractor via HybridStreamResolver) that live
  // playback already uses, instead of only the old Worker-only chain.
  final NativeAudioEngine _engine;
  DownloadProvider(this._engine);

  // PERF/SAFETY FIX (cold-start race): see followed_artists_provider.dart's
  // matching comment. isDownloaded/isDownloading/statusOf/offlineSongFor
  // already read the in-memory _items map (safe, defaults to {}), but
  // _persist/retry/deleteDownload touch _box directly — nullable +
  // Completer keeps those crash-safe too — this window is small in
  // practice but never fully zero, so it's guarded regardless.
  Box<Map>? _box;
  final Completer<Box<Map>> _boxReady = Completer<Box<Map>>();
  final Map<String, DownloadItem> _items = {}; // keyed by song.id
  final Map<String, CancelToken> _cancelTokens = {};
  // Songs whose current CancelToken.cancel() call was a deliberate pause
  // (pauseDownload) rather than a real cancel/failure — checked in
  // _runDownload's catch block to decide whether to persist `paused`
  // (keep the .part file) or `cancelled` (delete it). Removed the moment
  // that catch block reads it, so it never leaks between download attempts.
  final Set<String> _pausedTokens = {};

  bool _initialized = false;

  // ── FAST PLAYLIST DOWNLOAD ────────────────────────────────────────────────
  // "playlist details mai download ka option, ekdam fast download": runs
  // multiple songs of a playlist through the EXISTING, already-hardened
  // download(Song) path above (WiFi check, quality fallback, native-first
  // resolver, tuned Dio client, Hive persistence, notifications) — just N
  // songs at once instead of one at a time. This is not a second download
  // system: every song still goes through the exact same code as a single
  // manual download, so it shows up in the Downloads screen / isDownloaded()
  // / offline playback identically. The earlier draft of this feature
  // (aurum_fast_playlist_download.dart) built a fully separate Hive box +
  // Dio client + file layout that the rest of the app never knew about, and
  // it referenced a `song.downloadUrl` field that doesn't exist on the Song
  // model — it wouldn't have compiled. That file was not used here.
  final Set<String> _activePlaylistDownloads = {};

  bool isPlaylistDownloading(String playlistId) =>
      _activePlaylistDownloads.contains(playlistId);

  // Live progress for a playlist download in flight — (completed, total).
  // Purely derived from _items (already the source of truth for each
  // song's own status), so this needs no separate state to go stale.
  (int, int) playlistDownloadProgress(List<Song> songs) {
    final total = songs.length;
    final done = songs.where((s) => isDownloaded(s.id)).length;
    return (done, total);
  }

  /// Downloads every not-yet-downloaded song in [songs] concurrently, up to
  /// [maxConcurrent] at a time. Safe to call again while already running for
  /// the same [playlistId] — it's a no-op re-entry, matching download()'s
  /// own "safe to call multiple times" contract.
  Future<void> downloadPlaylist({
    required String playlistId,
    required List<Song> songs,
    int maxConcurrent = 4,
  }) async {
    if (songs.isEmpty) return;
    if (_activePlaylistDownloads.contains(playlistId)) return;

    _activePlaylistDownloads.add(playlistId);
    notifyListeners();

    try {
      // download() above already no-ops instantly for anything completed
      // or currently downloading, so skipping isDownloaded() here isn't
      // needed for correctness — but filtering the queue up front means
      // the concurrency slots are spent only on songs that actually need
      // a network round-trip, so a playlist that's mostly already offline
      // finishes as fast as just its missing songs, not the whole list.
      final pending = songs.where((s) => !isDownloaded(s.id)).toList();
      if (pending.isEmpty) return;

      final queue = List<Song>.from(pending);
      final workerCount = pending.length < maxConcurrent
          ? pending.length
          : maxConcurrent;

      Future<void> worker() async {
        while (queue.isNotEmpty) {
          if (!_activePlaylistDownloads.contains(playlistId)) return; // cancelled
          final song = queue.removeAt(0);
          try {
            await download(song);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('[Aurum] downloadPlaylist: ${song.id} failed: $e');
            }
          }
        }
      }

      await Future.wait(List.generate(workerCount, (_) => worker()));
    } finally {
      _activePlaylistDownloads.remove(playlistId);
      notifyListeners();
    }
  }

  /// Stops a playlist download in progress. Songs already mid-transfer via
  /// download() are cancelled individually the same way a single download
  /// would be (see cancelDownload below); songs not yet started simply
  /// never get picked up once the flag flips.
  void cancelPlaylistDownload(String playlistId, List<Song> songs) {
    _activePlaylistDownloads.remove(playlistId);
    for (final song in songs) {
      if (isDownloading(song.id)) cancelDownload(song.id);
    }
    notifyListeners();
  }

  List<DownloadItem> get items =>
      _items.values.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  List<DownloadItem> get completed =>
      items.where((d) => d.status == DownloadStatus.completed).toList();

  // Paused downloads still belong on the "In progress" tab (reference:
  // ArchiveTune keeps a paused item there with its progress bar frozen in
  // place, not tucked away as if it were done or failed) — only
  // completed/failed/cancelled leave this list.
  List<DownloadItem> get inProgress =>
      items.where((d) => d.isDownloading || d.isPaused).toList();

  bool isDownloaded(String songId) =>
      _items[songId]?.status == DownloadStatus.completed;

  bool isDownloading(String songId) => _items[songId]?.isDownloading ?? false;

  bool isPaused(String songId) => _items[songId]?.isPaused ?? false;

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
    final box = await Hive.openBox<Map>(_boxName);
    _box = box;
    _boxReady.complete(box);

    for (final raw in box.values) {
      try {
        final item = DownloadItem.fromJson(Map<String, dynamic>.from(raw));
        // Any download that was actively transferring when the app died is
        // now stale (no live CancelToken/isolate survives a process kill).
        // A `paused` item is different — it was deliberately left alone
        // with its `.part` file intentionally kept on disk, so it stays
        // `paused` across restarts and can still be resumed later; only
        // `downloading`/`queued` (genuinely interrupted, not deliberately
        // stopped) get demoted to `failed`.
        final fixed = item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.queued
            ? item.copyWith(status: DownloadStatus.failed)
            : item;
        _items[fixed.song.id] = fixed;
      } catch (_) {
        // skip corrupt entry
      }
    }

    // NOTE: NotificationService.instance.init() is intentionally NOT
    // called here. This init() runs synchronously during MultiProvider's
    // very first build (main.dart's DownloadProvider(engine)..init()) —
    // i.e. BEFORE runApp()'s first frame has painted. NotificationService
    // .init() does real platform-channel work (plugin init, notification
    // channel creation, and a requestNotificationsPermission() system
    // dialog request) that main.dart deliberately defers to AFTER
    // runApp() for exactly this reason — see the PERF FIX comment there.
    // Calling it again here would silently undo that fix and reintroduce
    // the cold-start stutter/hang it was written to prevent. Any download
    // action that needs NotificationService can rely on main.dart having
    // already triggered its init (it's idempotent — see `_initialized`
    // guard in notification_service.dart), so nothing here needs to
    // re-trigger it.
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist(DownloadItem item) async {
    _items[item.song.id] = item;
    // RELIABILITY: if the Hive write itself fails (disk full, box
    // corruption, rare OEM storage quirks), the in-memory `_items` map
    // above has already moved on to the new state, but nothing was
    // actually saved to disk — the next app launch would silently lose
    // this update even though the UI showed it as successful in this
    // session. Catch and log so this is at least visible in debug output
    // instead of failing completely silently; the in-memory state still
    // reflects the truth for the current session either way.
    try {
      final box = _box ?? await _boxReady.future;
      await box.put(item.song.id, item.toJson());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aurum] DownloadProvider: failed to persist ${item.song.id}: $e');
      }
    }
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

  /// Starts downloading a song. Safe to call multiple times — no-ops if
  /// already downloaded or currently downloading. To resume a paused
  /// download, use [resumeDownload] instead (this method always starts
  /// fresh from byte 0 for a genuinely new download).
  ///
  /// Returns true if the download actually started, false if it couldn't
  /// (e.g. no stream URL could be resolved) — callers use this to show
  /// the right feedback to the user.
  Future<bool> download(Song song) async {
    if (isDownloaded(song.id) || isDownloading(song.id)) return true;
    if (song.isLocal) return false;
    return _runDownload(song);
  }

  /// Resumes a `paused` download from where it left off, using the
  /// `.part` file and resolved URL already saved on its DownloadItem.
  /// Falls back to a fresh `download()` if the item isn't actually
  /// paused/known, or if its `.part` file has since disappeared.
  Future<bool> resumeDownload(Song song) async {
    final item = _items[song.id];
    if (item == null || !item.isPaused) return download(song);

    final dir = await _downloadsDir();
    final filePath = '${dir.path}/${_safeFileName(song)}';
    final tempFile = File('$filePath.part');
    final hasPartialFile =
        await tempFile.exists() && item.bytesDownloaded > 0;

    return _runDownload(
      song,
      resumeFromBytes: hasPartialFile ? item.bytesDownloaded : 0,
      knownUrl: item.resolvedUrl,
    );
  }

  /// Pauses a download in progress: cancels the in-flight transfer but
  /// deliberately leaves the `.part` file and its byte count on disk (the
  /// `deleteOnError`/cleanup path in [_runDownload]'s catch block is
  /// skipped for a pause, unlike a genuine cancel or failure) so
  /// [resumeDownload] can continue from that offset instead of
  /// re-downloading the whole file.
  Future<void> pauseDownload(String songId) async {
    final item = _items[songId];
    if (item == null || !item.isDownloading) return;
    // BUG FIX: if the user taps Pause while the song is still `queued`
    // (URL not resolved yet — cancelToken doesn't exist until _runDownload
    // reaches it, which is after an async URL-resolve step for Saavn
    // songs), the token lookup below is null and `.cancel()` becomes a
    // harmless no-op via `?.` — but _pausedTokens had already been marked,
    // so the download would carry on unpaused and the leftover flag would
    // wrongly mark some *future* unrelated cancel/failure of this song as
    // a pause. Guard: only mark paused if a live token actually exists.
    final token = _cancelTokens[songId];
    if (token == null) return;
    _pausedTokens.add(songId);
    token.cancel('paused');
  }

  Future<bool> _runDownload(
    Song song, {
    int resumeFromBytes = 0,
    String? knownUrl,
  }) async {

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
    // Only two real tiers are offered now (see settings_storage_screen.dart):
    // 320kbps and 160kbps. Quality order is deliberately SHORT — the user's
    // exact chosen tier first, with only ONE graceful step down to the next
    // real tier if that exact bitrate genuinely isn't available for this
    // song. Never drops further to 96/48/12kbps: a user who picked 320kbps
    // and silently got a 12kbps file (this used to happen — see
    // _extractSaavnStreamUrl's old "grab downloads.last" fallback) has no
    // way to know their download isn't what they asked for.
    final List<String> qualityOrder;
    switch (rawQuality) {
      case '160kbps':
        qualityOrder = const ['160kbps', '320kbps'];
        break;
      case '320kbps':
      default:
        qualityOrder = const ['320kbps', '160kbps'];
    }

    // Show "queued" immediately so the UI reacts instantly, even while we
    // resolve the actual stream URL (YouTube songs don't carry one upfront).
    // On resume, this also carries forward bytesDownloaded/resolvedUrl —
    // otherwise pausing (which shows real progress) would visually
    // "reset" to 0 for the instant between tapping Resume and the first
    // progress callback of the new transfer.
    await _persist(DownloadItem(
      song: song,
      status: DownloadStatus.queued,
      progress: resumeFromBytes > 0
          ? (_items[song.id]?.progress ?? 0.0)
          : 0.0,
      resolvedUrl: knownUrl,
      bytesDownloaded: resumeFromBytes,
    ));
    // Isolated: this runs before the try block below even starts, so an
    // uncaught throw here would previously crash download() entirely
    // before a single byte was ever requested.
    try {
      await NotificationService.instance.showProgress(
        songId: song.id,
        title: song.title,
        percent: (resumeFromBytes > 0
                ? ((_items[song.id]?.progress ?? 0.0) * 100)
                : 0)
            .round(),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aurum] DownloadProvider: initial showProgress failed for ${song.id} (continuing anyway): $e');
      }
    }

    // Resuming with an already-known URL skips re-resolving entirely — a
    // fresh resolve can hand back a different CDN URL than the one the
    // `.part` file's bytes were already downloaded against, which would
    // make a Range-based resume against the new URL invalid/mismatched.
    String? url = knownUrl ?? (song.source == SongSource.saavn ? null : song.streamUrl);
    // FLOOR FIX (Saavn only): a pre-populated song.streamUrl (e.g. from a
    // search result's media_url field) carries no known bitrate — see
    // _extractSaavnStreamUrl's media_url fallback, which explicitly sets
    // AudioPrefs.lastResolvedKbps = null because that shape doesn't report
    // a tier at all. Using it as-is here would let a Saavn download
    // silently skip the quality resolution below entirely, bypassing the
    // 160kbps floor for a URL of literally unknown quality. Saavn always
    // re-resolves fresh through resolveDownloadUrl (which the floor check
    // right below then verifies), so the floor is enforced unconditionally
    // for every Saavn download, not just ones that needed a fresh resolve.
    // YouTube-sourced songs are unaffected — their streamUrl (when present)
    // is kept as before, and they don't carry Saavn-style kbps tiers to
    // floor-check in the first place.
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
        // RETRY FIX ("Couldn't download — stream unavailable" even while the
        // exact same song plays fine): resolveForDownload used to be a
        // single one-shot native attempt. Playback looks more reliable not
        // because its resolver is different, but because prewarm/replay
        // gives it multiple implicit chances over time; a download only
        // ever got one. YoutubeInnertube can fail on a transient blip
        // (cipher parse hiccup, one bad connection) and succeed moments
        // later on literally the same video — so retry natively a couple
        // times with a short gap before ever falling through to the Worker
        // (which has its own, separate reliability issues). Falling to the
        // Worker only after native has genuinely had a fair shot avoids
        // wasting a download on a Worker outage when native would have
        // worked on attempt 2.
        if (song.source == SongSource.youtube) {
          for (var attempt = 0; attempt < 3 && url == null; attempt++) {
            if (attempt > 0) {
              await Future.delayed(Duration(milliseconds: 800 * attempt));
            }
            url = await _engine.resolveForDownload(song);
          }
        }
        // Worker fallback also gets a couple of tries — same rationale,
        // since a single Worker call losing its internal race isn't
        // necessarily the Worker actually being down.
        for (var attempt = 0; attempt < 2 && (url == null || url.isEmpty); attempt++) {
          if (attempt > 0) {
            await Future.delayed(const Duration(milliseconds: 1000));
          }
          url = await ApiService.resolveDownloadUrl(song, qualityOrder: qualityOrder);
        }
      } catch (_) {
        url = null;
      }

      // FLOOR (Saavn only): never accept a Saavn download below 160kbps.
      // resolveDownloadUrl/_extractSaavnStreamUrl can still fall through to
      // "best available in this song's list" when neither requested tier
      // matches — for a song whose list tops out at, say, 96kbps, that's
      // still below the 160/320kbps floor this app now promises. Reject it
      // outright here rather than silently handing over a sub-160kbps file.
      // Doesn't apply to YouTube-sourced downloads (_engine.resolveForDownload
      // above) — those don't carry discrete Saavn-style kbps tiers at all.
      if (song.source == SongSource.saavn &&
          url != null &&
          AudioPrefs.lastResolvedKbps != null &&
          AudioPrefs.lastResolvedKbps! < 160) {
        url = null;
      }
    }

    if (url == null || url.isEmpty) {
      await _persist(_items[song.id]!.copyWith(status: DownloadStatus.failed));
      try {
        await NotificationService.instance.showFailed(
          songId: song.id,
          title: song.title,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Aurum] DownloadProvider: showFailed notification failed for ${song.id}: $e');
        }
      }
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
        _items[song.id]!.copyWith(
          status: DownloadStatus.downloading,
          resolvedUrl: url,
        ),
      );

      int lastNotifiedPercent = -1;
      // Resuming a paused download appends to the existing `.part` file
      // rather than truncating it — Dio's `download()` always overwrites,
      // so a resume opens the file itself in append mode via a Range
      // request instead.
      final isResume = resumeFromBytes > 0;
      final tempFile = File(tempPath);
      final finalFile = File(filePath);

      if (isResume) {
        // ── Resume path: Range request, append to existing bytes ──────────
        final response = await _downloadClient.get<ResponseBody>(
          url,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 60),
            headers: {
              'Range': 'bytes=$resumeFromBytes-',
              if (song.source == SongSource.youtube)
                'Referer': 'https://www.youtube.com/',
            },
          ),
        );

        // A server that ignores Range and returns 200 (full content) can't
        // be safely appended to — restart that one attempt from scratch
        // rather than corrupting the file with a duplicated prefix.
        final isPartialContent = response.statusCode == 206;
        final sink = await tempFile.open(
          mode: isPartialContent ? FileMode.append : FileMode.write,
        );
        var received = isPartialContent ? resumeFromBytes : 0;
        final contentLength = response.data?.contentLength ?? -1;
        final total = isPartialContent && contentLength > 0
            ? resumeFromBytes + contentLength
            : contentLength;

        try {
          // BUG FIX: bytesDownloaded must be persisted every tick regardless
          // of whether `total` is known — previously this only happened
          // inside the `if (total > 0)` branch, so a server that omits
          // Content-Length on a Range response (total <= 0) never wrote
          // `received` to disk. If the app died mid-resume in that state,
          // the next resumeDownload would restart from the old, smaller
          // saved offset while the `.part` file already had more bytes —
          // duplicating that overlap into the appended file (corrupt
          // audio). Byte-offset persistence must not depend on knowing the
          // total; only the percent/progress UI does.
          int lastPersistedBytes = resumeFromBytes;
          await for (final chunk in response.data!.stream) {
            await sink.writeFrom(chunk);
            received += chunk.length;

            final hasTotal = total > 0;
            final progress = hasTotal ? received / total : null;
            final percent = hasTotal ? (progress! * 100).round() : null;

            // Throttle disk writes the same way the known-total path does
            // (avoid fighting the file write for I/O), but using a byte
            // delta instead of percent when percent isn't available.
            final shouldPersist = hasTotal
                ? percent != lastNotifiedPercent
                : (received - lastPersistedBytes) >= 262144; // 256KB steps

            if (!shouldPersist) continue;

            final current = _items[song.id];
            if (current == null) continue;
            await _persist(current.copyWith(
              progress: progress ?? current.progress,
              bytesDownloaded: received,
            ));
            lastPersistedBytes = received;

            if (hasTotal && percent != lastNotifiedPercent) {
              lastNotifiedPercent = percent!;
              try {
                await NotificationService.instance.showProgress(
                  songId: song.id,
                  title: song.title,
                  percent: percent,
                );
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('[Aurum] DownloadProvider: showProgress notification failed for ${song.id} at $percent% (transfer continues): $e');
                }
              }
            }
          }
        } finally {
          await sink.close();
        }
      } else {
        // ── Fresh download path — unchanged from before ────────────────────
        await _downloadClient.download(
          url,
          tempPath,
          cancelToken: cancelToken,
          // SPEED FIX: explicit large receive buffer + deleteOnError so a
          // failed transfer doesn't leave a corrupt partial file mistaken
          // for a resumable one on the next attempt. NOTE: a *paused*
          // transfer never reaches this deleteOnError behavior — pausing
          // cancels the token, which Dio surfaces as a normal
          // DioException, caught below (deleteOnError only fires Dio's
          // own internal cleanup on a genuine transfer error, not on a
          // caller-issued cancel).
          deleteOnError: true,
          options: Options(
            receiveTimeout: const Duration(seconds: 60),
            // SPEED FIX (YouTube specifically): googlevideo.com also checks
            // Referer on top of User-Agent — a request with a UA but no
            // Referer can still get throttled. Harmless no-op for Saavn's
            // CDN, which doesn't check this header at all, so it's safe to
            // send unconditionally rather than branching on song.source.
            headers: song.source == SongSource.youtube
                ? {'Referer': 'https://www.youtube.com/'}
                : null,
          ),
          onReceiveProgress: (received, total) async {
            if (total <= 0) return;
            final progress = received / total;
            final percent = (progress * 100).round();

            // SPEED FIX: this callback fires many times per second on a
            // fast connection — persisting (Hive disk write) on every call
            // was fighting the file-write for the same disk I/O and
            // slowing the transfer on low-end devices. Only persist +
            // notify when the whole-percent value actually changes, same
            // cadence as the notification below, instead of on every raw
            // byte-count tick.
            if (percent == lastNotifiedPercent) return;

            final current = _items[song.id];
            if (current == null) return;

            await _persist(current.copyWith(
              progress: progress,
              bytesDownloaded: received,
            ));

            // Only push a notification update every whole percent to avoid spam.
            if (percent != lastNotifiedPercent) {
              lastNotifiedPercent = percent;
              // Same isolation as showCompleted() below: a notification
              // platform-channel hiccup here must never be allowed to
              // propagate up through Dio's onReceiveProgress and abort an
              // otherwise-healthy file transfer that might be seconds from
              // finishing successfully.
              try {
                await NotificationService.instance.showProgress(
                  songId: song.id,
                  title: song.title,
                  percent: percent,
                );
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('[Aurum] DownloadProvider: showProgress notification failed for ${song.id} at $percent% (transfer continues): $e');
                }
              }
            }
          },
        );
      }

      // Move temp -> final so a half-written file is never mistaken as done.
      if (await finalFile.exists()) await finalFile.delete();
      await tempFile.rename(filePath);

      final size = await finalFile.length();

      // Downloads are kept entirely in the app's own private storage —
      // never copied to the public Music/Astra folder, so they never show
      // up in the device's file manager or other apps. Offline playback
      // inside Aurum itself works exactly the same either way; this only
      // controls whether a copy also becomes visible outside the app.
      final String finalLocalPath = filePath;

      // ROOT FIX ("download completes but doesn't save / disappears from
      // the list"): showCompleted() below is a platform-channel call
      // (flutter_local_notifications). On stricter OEM ROMs — including
      // the same Realme/ColorOS class of device this app already works
      // around elsewhere for background kills — a notification call can
      // throw (permission not yet granted, channel not ready, OEM
      // notification restrictions) even though the actual download
      // finished perfectly and was already correctly persisted as
      // `completed` just above. The old code called showCompleted()
      // *inside* this same try block, so that throw fell into the catch
      // clause below — which unconditionally overwrote the just-saved
      // `completed` status back to `failed`. The song's file was still
      // sitting on disk the whole time; only the saved Hive record (and
      // therefore the Downloads list the user actually sees) got
      // silently corrupted back to "failed" by a notification hiccup
      // that had nothing to do with whether the download itself worked.
      //
      // Fix: persist `completed` and return true FIRST — the download is
      // unambiguously done and saved at that point, full stop. The
      // completion notification is then best-effort and isolated in its
      // own try/catch that can never affect the already-saved status.
      await _persist(_items[song.id]!.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        localPath: finalLocalPath,
        fileSizeBytes: size,
      ));

      try {
        await NotificationService.instance.showCompleted(
          songId: song.id,
          title: song.title,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Aurum] DownloadProvider: showCompleted notification failed for ${song.id} (download itself succeeded and is saved): $e');
        }
      }
      return true;
    } catch (e) {
      // A deliberate pause (pauseDownload) also cancels the token, so it
      // lands in this same catch block — checked first, before the
      // generic cancel/failure handling, since a pause must NOT delete
      // the `.part` file the way a real cancel/failure does below.
      final wasPaused = _pausedTokens.remove(song.id);
      if (wasPaused && cancelToken.isCancelled) {
        final partial = File(tempPath!);
        final bytesOnDisk = await partial.exists() ? await partial.length() : 0;
        await _persist(_items[song.id]!.copyWith(
          status: DownloadStatus.paused,
          bytesDownloaded: bytesOnDisk,
        ));
        try {
          await NotificationService.instance.cancelProgress(song.id);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[Aurum] DownloadProvider: cancelProgress notification failed for ${song.id}: $e');
          }
        }
        return false;
      }

      // FIX (2026-07-02): clean up the orphaned partial file left behind on
      // cancel/failure — previously nothing deleted this, so every
      // cancelled or failed download quietly left a `.part` file on disk
      // forever, wasting storage over time. A pause (handled above) is
      // deliberately exempt from this — its `.part` file is kept on
      // purpose so resumeDownload has something to continue from.
      if (tempPath != null) {
        try {
          final leftover = File(tempPath);
          if (await leftover.exists()) await leftover.delete();
        } catch (_) {}
      }

      if (cancelToken.isCancelled) {
        await _persist(_items[song.id]!.copyWith(status: DownloadStatus.cancelled));
        try {
          await NotificationService.instance.cancelProgress(song.id);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[Aurum] DownloadProvider: cancelProgress notification failed for ${song.id}: $e');
          }
        }
        return false;
      } else {
        await _persist(_items[song.id]!.copyWith(status: DownloadStatus.failed));
        try {
          await NotificationService.instance.showFailed(
            songId: song.id,
            title: song.title,
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[Aurum] DownloadProvider: showFailed notification failed for ${song.id}: $e');
          }
        }
        return false;
      }
    } finally {
      _cancelTokens.remove(song.id);
    }
  }

  /// Cancels an active or paused download. A `downloading`/`queued` item
  /// has a live CancelToken, handled the normal way; a `paused` item's
  /// token is already gone (its transfer already finished cancelling when
  /// it paused) so cancelling it here instead deletes its kept-around
  /// `.part` file directly and marks it `cancelled`.
  Future<void> cancelDownload(String songId) async {
    final item = _items[songId];
    if (item != null && item.isPaused) {
      final dir = await _downloadsDir();
      final tempPath = '${dir.path}/${_safeFileName(item.song)}.part';
      try {
        final leftover = File(tempPath);
        if (await leftover.exists()) await leftover.delete();
      } catch (_) {}
      await _persist(item.copyWith(status: DownloadStatus.cancelled));
      try {
        await NotificationService.instance.cancelProgress(songId);
      } catch (_) {}
      return;
    }
    _cancelTokens[songId]?.cancel();
  }

  Future<void> retry(Song song) async {
    _items.remove(song.id);
    final box = _box ?? await _boxReady.future;
    await box.delete(song.id);
    await download(song);
  }

  /// Deletes a completed download's file AND its list entry — in that
  /// order, and only removes the list entry if the file delete actually
  /// succeeded.
  ///
  /// FIX ("delete karta hu to file gayab hi nahi hoti"): the old version
  /// called File(path).delete() and completely discarded its result —
  /// `_items.remove(songId)` ran unconditionally right after, regardless
  /// of whether the delete actually worked. Two ways that silently left
  /// an orphaned file on disk while the app showed the download as gone:
  ///   1. A plain File.delete() failing for any reason (locked file, OEM
  ///      storage quirk, permission hiccup) was never surfaced or retried
  ///      — the code just moved on.
  ///   2. Once downloads started being saved to the public Music/Astra
  ///      folder via MediaStore (see saveDownloadToPublicMusic), localPath
  ///      can now be a content:// URI instead of a plain file path — a
  ///      raw File(path).delete() on a content:// string is a no-op that
  ///      neither deletes anything nor throws, so it "succeeds" while
  ///      doing nothing.
  /// Now routes through NativeEngineBridge.deletePublicDownload, which
  /// handles both a MediaStore URI (via ContentResolver.delete) and a
  /// plain private-storage path (via File.delete) correctly, and reports
  /// back whether the row/file is actually gone. The list entry is only
  /// removed when that comes back true.
  Future<bool> deleteDownload(String songId) async {
    final item = _items[songId];
    if (item?.localPath != null && item!.localPath!.isNotEmpty) {
      final deleted = await _engine.deletePublicDownload(item.localPath!);
      if (!deleted) {
        if (kDebugMode) {
          debugPrint('[Aurum] DownloadProvider: failed to delete file for $songId at ${item.localPath} — keeping list entry so the orphaned file stays visible/retryable');
        }
        return false;
      }
    }
    // A paused item's `.part` file was deliberately kept on disk to
    // support resumeDownload — deleting the item entirely (as opposed to
    // just cancelling it) must clean that up too, or it leaks forever.
    if (item != null && item.isPaused) {
      final dir = await _downloadsDir();
      final tempPath = '${dir.path}/${_safeFileName(item.song)}.part';
      try {
        final leftover = File(tempPath);
        if (await leftover.exists()) await leftover.delete();
      } catch (_) {}
    }
    _items.remove(songId);
    final box = _box ?? await _boxReady.future;
    await box.delete(songId);
    await NotificationService.instance.cancelProgress(songId);
    notifyListeners();
    return true;
  }

  /// Total space used by all completed downloads, in bytes.
  int get totalBytesUsed => completed.fold(0, (sum, d) => sum + (d.fileSizeBytes ?? 0));
}
