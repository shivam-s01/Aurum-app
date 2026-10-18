import 'package:aurum_music/widgets/aurum_loader.dart';
import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';

class ChangelogSection {
  final String title;
  final List<String> items;
  const ChangelogSection(this.title, this.items);
}

class _LatestBuild {
  final int build;
  final String url;
  const _LatestBuild(this.build, this.url);
}

class UpdateService {
  static const _repo = 'shivam-s01/Aurum-app';
  // Exact same two-call pattern Musify uses (gokadzev/Musify):
  // 1) check.json on the 'update' branch via raw.githubusercontent.com
  //    — no auth, no rate limit — just to compare version numbers.
  // 2) Only if that shows a newer version, THEN call the GitHub
  //    Releases API (unauthenticated, 60 req/hour shared per IP) to
  //    fetch the changelog body. This second call only ever fires for
  //    the (rare) subset of launches where an update actually exists,
  //    not on every single launch — so it stays far under the limit
  //    Musify itself has shipped at scale with.
  static const _checkUrl =
      'https://raw.githubusercontent.com/$_repo/update/check.json';
  static const _releasesUrl =
      'https://api.github.com/repos/$_repo/releases/latest';
  static const _channel = MethodChannel('com.aurum.music/media_store');

  // Persisted dismiss: "Later" hides the popup for 12 hours, tracked
  // per-version so a newer release always breaks through the cooldown.
  static const _prefsDismissedVersion = 'update_dismissed_version';
  static const _prefsDismissedAt = 'update_dismissed_at_millis';
  static const Duration _snoozeDuration = Duration(hours: 12);

  /// [silent] suppresses the "no update" UI (used for background/launch
  /// checks). [force] bypasses the 12h snooze (used for the manual
  /// Settings "Check for Update" tap, so the user always gets a fresh
  /// answer when they explicitly ask).
  static Future<void> checkForUpdate(
    BuildContext context, {
    bool silent = true,
    bool force = false,
  }) async {
    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      // Primary: check.json (raw.githubusercontent.com — no rate limit).
      // Fallback: Releases API (tag "build<N>" + apk asset). Either one
      // answering is enough, so a missing/stale check.json or a CDN hiccup
      // can't break the update flow anymore.
      final latest = await _fetchLatest();

      if (latest == null) {
        if (kDebugMode) {
          debugPrint('[Aurum] UpdateService: no update info reachable (silent=$silent)');
        }
        if (!silent && context.mounted) _showCheckFailed(context);
        return;
      }

      if (latest.build <= currentBuild) {
        if (!silent && context.mounted) _showUpToDate(context);
        return;
      }

      final versionLabel = 'build${latest.build}';

      if (!force && await _isSnoozed(versionLabel)) return;

      // Changelog is best-effort — popup must show even without it.
      var highlights = const <ChangelogSection>[];
      try {
        final res = await http
            .get(Uri.parse(_releasesUrl), headers: _ghHeaders)
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          highlights = _parseHighlights(body['body']?.toString() ?? '');
        }
      } catch (_) {}

      if (context.mounted) {
        _showDialog(
          context,
          version: versionLabel,
          displayName: versionLabel,
          url: latest.url,
          highlights: highlights,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aurum] UpdateService: checkForUpdate threw (silent=$silent): $e');
      }
      if (!silent && context.mounted) _showCheckFailed(context);
    }
  }

  static const Map<String, String> _ghHeaders = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'AstraMusic-Updater',
  };

  /// Tries check.json (2 attempts), then the Releases API. Returns null
  /// only if every source failed.
  static Future<_LatestBuild?> _fetchLatest() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final url = Uri.parse(_checkUrl).replace(
          queryParameters: {'t': DateTime.now().millisecondsSinceEpoch.toString()},
        );
        final res = await http
            .get(url, headers: const {'Cache-Control': 'no-cache'})
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final map = jsonDecode(res.body) as Map<String, dynamic>;
          final build = int.tryParse(map['buildNumber']?.toString() ?? '');
          final apkUrl = map['url']?.toString() ?? '';
          if (build != null && apkUrl.isNotEmpty) return _LatestBuild(build, apkUrl);
        }
      } catch (_) {}
      if (attempt == 0) await Future.delayed(const Duration(milliseconds: 600));
    }

    try {
      final res = await http
          .get(Uri.parse(_releasesUrl), headers: _ghHeaders)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final map = jsonDecode(res.body) as Map<String, dynamic>;
        final tag = map['tag_name']?.toString() ?? '';
        final build = int.tryParse(tag.replaceAll(RegExp(r'[^0-9]'), ''));
        final assets = (map['assets'] as List?) ?? const [];
        String apk = '';
        for (final a in assets) {
          final u = (a as Map)['browser_download_url']?.toString() ?? '';
          if (u.endsWith('.apk')) {
            apk = u;
            break;
          }
        }
        if (build != null && apk.isNotEmpty) {
          // The tag is the raw build number, but the phone's PackageInfo
          // reports the real versionCode, which Flutter's --split-per-abi
          // raises by an ABI offset (check.json already carries the real
          // one). Add the same offset here so both sources compare against
          // the installed build identically — otherwise a build less than
          // ~33 min newer would be missed when this fallback is used.
          final offset = apk.contains('arm64-v8a')
              ? 2000
              : apk.contains('armeabi-v7a')
                  ? 1000
                  : apk.contains('x86_64')
                      ? 4000
                      : 0;
          return _LatestBuild(build + offset, apk);
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> _isSnoozed(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final dismissedVersion = prefs.getString(_prefsDismissedVersion);
    if (dismissedVersion != version) return false;
    final dismissedAt = prefs.getInt(_prefsDismissedAt);
    if (dismissedAt == null) return false;
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(dismissedAt),
    );
    return elapsed < _snoozeDuration;
  }

  static Future<void> _snooze(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsDismissedVersion, version);
    await prefs.setInt(_prefsDismissedAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// Turns a GitHub release body into a structured, categorized
  /// changelog for the popup — groups bullets under their "## Heading"
  /// section instead of flattening everything into one undifferentiated
  /// list. Caps at 3 sections and 3 bullets per section so the dialog
  /// stays compact and scannable (a Spotify-style "what's new" card
  /// reads as organized, not as a wall of text).
  static List<ChangelogSection> _parseHighlights(String body) {
    if (body.trim().isEmpty) return const [];

    final lines = body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);

    final sections = <ChangelogSection>[];
    String? currentTitle;
    List<String> currentItems = [];

    void flush() {
      if (currentTitle != null && currentItems.isNotEmpty) {
        sections.add(ChangelogSection(currentTitle!, currentItems.take(3).toList()));
      }
    }

    for (final line in lines) {
      final headingMatch = RegExp(r'^#{1,6}\s*(.+)$').firstMatch(line);
      if (headingMatch != null) {
        flush();
        currentTitle = headingMatch.group(1)!.trim();
        currentItems = [];
        continue;
      }
      final bulletMatch = RegExp(r'^[-*•]\s*(.+)$').firstMatch(line);
      if (bulletMatch != null) {
        // A bullet before any heading (e.g. a hand-written release with
        // no "## " sections) still needs a home — group those under a
        // generic title rather than dropping them silently.
        currentTitle ??= 'Changes';
        currentItems.add(bulletMatch.group(1)!.trim());
      }
    }
    flush();

    return sections.take(3).toList();
  }

  static void _showDialog(
    BuildContext context, {
    required String version,
    required String displayName,
    required String url,
    required List<ChangelogSection> highlights,
  }) {
    showDialog(
      context: context,
      // FIX ("gray/dark screen stuck permanently, only app restart clears
      // it" — production bug): this was barrierDismissible: false, on the
      // reasoning that a user shouldn't accidentally miss an update
      // prompt. But that trade only makes sense if the dialog CONTENT is
      // guaranteed to render — if _UpdateDialog's build ever throws
      // (malformed highlights from a release body, a null/empty url, a
      // BackdropFilter/GPU hiccup on a given device, anything), Flutter
      // has already inserted the barrier route before builder() runs, so
      // a throw there leaves exactly the barrierColor scrim on screen
      // with no content and no tap-to-dismiss — permanently, since
      // barrierDismissible:false blocks the one recovery path a plain
      // barrier normally has. That matches "sirf restart se jaata hai"
      // exactly: nothing short of killing the process clears a route
      // that's on the stack but was never popped and can't be tapped
      // away. Missing an update prompt once is a trivial inconvenience
      // (it re-checks next launch); a permanently stuck unresponsive
      // screen is not. Back-gesture/tap-outside is now always a valid
      // escape hatch regardless of what happens inside the dialog.
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (dialogContext) {
        // FIX (same bug, second half): if _UpdateDialog itself throws
        // during build despite the above, catch it here rather than
        // letting the exception propagate up through showDialog's own
        // builder — an uncaught throw here still leaves the barrier
        // route on the stack with nothing painted for its content slot.
        // Falling back to an empty, auto-dismissing SizedBox means the
        // absolute worst case is "the update prompt silently didn't
        // show this launch" instead of "app is stuck until restart".
        try {
          return _UpdateDialog(
            version: version,
            highlights: highlights,
            url: url,
            onDismiss: () => _snooze(version),
          );
        } catch (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(dialogContext).canPop()) {
              Navigator.of(dialogContext).pop();
            }
          });
          return const SizedBox.shrink();
        }
      },
    );
  }

  static void _showUpToDate(BuildContext context) {
    _showToast(context, icon: Icons.check_circle_rounded, message: "You're on the latest version");
  }

  static void _showCheckFailed(BuildContext context) {
    _showToast(context, icon: Icons.cloud_off_rounded, message: "Couldn't check for updates");
  }

  static void _showToast(BuildContext context, {required IconData icon, required String message}) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _UpdateToast(icon: icon, message: message, onDone: () => entry.remove()),
    );
    overlay.insert(entry);
  }

  static Future<void> installApk(String path) async {
    try {
      await _channel.invokeMethod('installApk', {'path': path});
    } catch (e) {
      debugPrint('installApk error: $e');
      rethrow;
    }
  }

  // FIX ("update install/uninstall jaisa lagta hai"): installApk() above
  // only confirms the PackageInstaller session was STARTED — the real
  // outcome (user confirmed the update prompt and it succeeded, they
  // dismissed it, or it failed) arrives later via this native→Dart
  // callback, since a session can be waiting on a user tap for several
  // seconds. Callers (currently just _UpdateDialog) register here to
  // reflect the actual result instead of assuming success the instant
  // installApk's method call returns.
  static void Function(bool success, String message)? onInstallResult;

  static void wireInstallResultHandler() {
    // FIX ("updates jaana band ho gaya sabke liye" — regression from the
    // silent-install change): this handler runs on _channel
    // ('com.aurum.music/media_store'), which THE SAME static channel
    // object every other service (LocalMusicService, DiagnosticLogService,
    // AudioPrefs, NativeRelatedVideos, and checkForUpdate/installApk right
    // here) also calls invokeMethod on. setMethodCallHandler only affects
    // INCOMING calls (native→Dart) — it does not block outgoing
    // invokeMethod calls made by those other services, so this by itself
    // was never the cause of updates failing to reach users.
    //
    // The real risk was narrower but real: if this callback ever threw
    // (a malformed/unexpected `call.arguments` shape, or literally any
    // other method someone adds to this channel in the future landing
    // here unhandled), the exception propagates back through the
    // platform channel machinery as an uncaught error. That doesn't
    // crash invokeMethod callers immediately, but on some Flutter engine
    // versions an uncaught platform-channel handler exception can leave
    // the channel's isolate-side dispatcher in a bad state for
    // *subsequent* calls on that same channel — which would silently
    // break every other media_store call after it, including the ones
    // checkForUpdate's installApk() depends on. Hardened below so this
    // handler can never throw, no matter what arrives on this channel:
    // only ever reacts to the one method it knows about, everything else
    // (including malformed args) is ignored rather than crashing.
    _channel.setMethodCallHandler((call) async {
      try {
        if (call.method != 'onInstallResult') return null;
        final rawArgs = call.arguments;
        if (rawArgs is! Map) return null;
        final args = Map<String, dynamic>.from(rawArgs);
        onInstallResult?.call(
          args['success'] as bool? ?? false,
          args['message'] as String? ?? '',
        );
      } catch (e) {
        debugPrint('[Aurum] UpdateService: onInstallResult handler error (ignored): $e');
      }
      return null;
    });
  }
}

class _UpdateToast extends StatefulWidget {
  final IconData icon;
  final String message;
  final VoidCallback onDone;
  const _UpdateToast({required this.icon, required this.message, required this.onDone});

  @override
  State<_UpdateToast> createState() => _UpdateToastState();
}

class _UpdateToastState extends State<_UpdateToast> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AurumMotion.medium1);
    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 1800), () async {
      if (!mounted) return;
      await _ctrl.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final textP = AurumTheme.textPrimaryOf(context);
    return Positioned(
      bottom: 100,
      left: 24,
      right: 24,
      child: FadeTransition(
        opacity: _ctrl,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
              .animate(CurvedAnimation(parent: _ctrl, curve: AurumMotion.standard)),
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      color: AurumTheme.bgElevatedOf(context),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: textP.withOpacity(0.08)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(widget.icon, color: accent, size: 18),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(widget.message,
                            style: TextStyle(
                                color: textP, fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final String version;
  final List<ChangelogSection> highlights;
  final String url;
  final VoidCallback onDismiss;
  const _UpdateDialog({
    required this.version,
    required this.highlights,
    required this.url,
    required this.onDismiss,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> with SingleTickerProviderStateMixin {
  double _progress = 0;
  int _received = 0;
  int _total = 0;
  bool _downloading = false;
  bool _installing = false;
  bool _error = false;
  String _status = '';
  DateTime _lastUiTick = DateTime.fromMillisecondsSinceEpoch(0);
  late final AnimationController _entryCtrl;

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(vsync: this, duration: AurumMotion.medium2);
    _entryCtrl.forward();
    // Real install outcome arrives asynchronously from the native
    // PackageInstaller; a hard failure lands here while the dialog is up.
    UpdateService.onInstallResult = (success, message) {
      if (!mounted) return;
      if (!success) {
        setState(() {
          _downloading = false;
          _installing = false;
          _error = true;
          _status = message.isNotEmpty ? message : 'Install failed. Please try again.';
        });
      }
    };
  }

  @override
  void dispose() {
    UpdateService.onInstallResult = null;
    _entryCtrl.dispose();
    super.dispose();
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _downloadAndInstall() async {
    AurumHaptics.medium();
    setState(() {
      _downloading = true;
      _installing = false;
      _error = false;
      _progress = 0;
      _received = 0;
      _total = 0;
    });
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/aurum-update.apk';

      final oldFile = File(path);
      if (await oldFile.exists()) await oldFile.delete();

      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
      await dio.download(
        widget.url,
        path,
        options: Options(
          headers: {'Accept': 'application/vnd.android.package-archive'},
          responseType: ResponseType.bytes,
        ),
        onReceiveProgress: (received, total) {
          if (!mounted) return;
          // ~8 repaints/second max so the download never janks the UI.
          final now = DateTime.now();
          if (now.difference(_lastUiTick).inMilliseconds < 120 && received != total) return;
          _lastUiTick = now;
          setState(() {
            _received = received;
            if (total > 0) {
              _total = total;
              _progress = received / total;
            }
          });
        },
      );
      if (!mounted) return;

      final size = await File(path).length();
      if (size < 1024 * 1024) {
        if (!mounted) return;
        setState(() {
          _downloading = false;
          _error = true;
          _status = 'The download didn\'t finish. Please try again.';
        });
        return;
      }

      setState(() {
        _installing = true;
        _progress = 1.0;
      });
      AurumHaptics.light();
      await Future.delayed(const Duration(milliseconds: 350));
      await UpdateService.installApk(path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _installing = false;
        _error = true;
        _status = 'Couldn\'t download the update. Check your connection and try again.';
      });
    }
  }

  // ── Pieces ────────────────────────────────────────────────────────────

  Widget _header(BuildContext context, Color accent, Color onAccent, Color textP) {
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            gradient: AurumTheme.accentGradientOf(context),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(Icons.music_note_rounded, color: onAccent, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _installing
                    ? 'Installing update'
                    : _downloading
                        ? 'Downloading update'
                        : 'Update available',
                style: TextStyle(
                  color: textP,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Astra Music',
                style: TextStyle(
                  color: textP.withOpacity(0.5),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _notes(Color accent, Color textP) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < widget.highlights.length; i++) ...[
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 14, bottom: 8),
            child: Text(
              widget.highlights[i].title.toUpperCase(),
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final item in widget.highlights[i].items)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(color: textP.withOpacity(0.45), shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(color: textP.withOpacity(0.8), fontSize: 13.5, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _progressBlock(Color accent, Color textP) {
    final pct = (_progress * 100).clamp(0, 100).toInt();
    final String right;
    if (_installing) {
      right = '';
    } else if (_total > 0) {
      right = '${_mb(_received)} of ${_mb(_total)} MB';
    } else {
      right = '${_mb(_received)} MB';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 6,
            child: _installing
                ? const AurumM3Loader(height: 6, borderRadius: 6)
                : LinearProgressIndicator(
                    value: _total > 0 ? _progress : null,
                    minHeight: 6,
                    backgroundColor: textP.withOpacity(0.08),
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              _installing ? 'Confirm the Android prompt to finish' : '$pct%',
              style: TextStyle(
                color: textP.withOpacity(0.75),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(right, style: TextStyle(color: textP.withOpacity(0.5), fontSize: 13)),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final textP = AurumTheme.textPrimaryOf(context);
    final card = AurumTheme.bgElevatedOf(context);
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : Colors.black;
    final curved = CurvedAnimation(parent: _entryCtrl, curve: AurumMotion.standard);
    final maxBody = MediaQuery.of(context).size.height * 0.38;
    final hasNotes = widget.highlights.isNotEmpty;
    const red = Color(0xFFE86B6B);

    return PopScope(
      // No accidental dismiss while a download/install is in flight.
      canPop: !_downloading,
      child: FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Container(
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: textP.withOpacity(0.08)),
              ),
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, accent, onAccent, textP),
                  const SizedBox(height: 18),

                  if (_downloading)
                    _progressBlock(accent, textP)
                  else ...[
                    if (hasNotes)
                      Flexible(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: maxBody),
                          child: SingleChildScrollView(
                            physics: const ClampingScrollPhysics(),
                            child: _notes(accent, textP),
                          ),
                        ),
                      )
                    else
                      Text(
                        'A new version is ready with the latest improvements and fixes.',
                        style: TextStyle(
                          color: textP.withOpacity(0.75),
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    const SizedBox(height: 14),
                    Text(
                      'Installs over the current app. Your library and downloads stay safe.',
                      style: TextStyle(color: textP.withOpacity(0.45), fontSize: 12.5, height: 1.4),
                    ),
                  ],

                  if (_error) ...[
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline_rounded, color: red, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _status,
                            style: const TextStyle(color: red, fontSize: 12.5, height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ],

                  if (!_downloading) ...[
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () {
                              AurumHaptics.selection();
                              widget.onDismiss();
                              Navigator.pop(context);
                            },
                            child: Text(
                              'Later',
                              style: TextStyle(
                                color: textP.withOpacity(0.6),
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: _downloadAndInstall,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: onAccent,
                              elevation: 0,
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            child: Text(
                              _error ? 'Retry' : 'Update',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
