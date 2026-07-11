import 'package:aurum_music/widgets/aurum_loader.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';

class UpdateService {
  static const _repo = 'shivam-s01/Aurum-app';
  static const _apiUrl = 'https://api.github.com/repos/$_repo/releases/latest';
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

      final response = await http
          .get(Uri.parse(_apiUrl),
              headers: {'Accept': 'application/vnd.github.v3+json'})
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        if (!silent && context.mounted) _showCheckFailed(context);
        return;
      }

      final data = jsonDecode(response.body);
      final latestTag = data['tag_name'] as String? ?? '';
      final releaseName = data['name'] as String? ?? '';
      final body = data['body'] as String? ?? '';
      final assets = data['assets'] as List<dynamic>? ?? [];
      if (assets.isEmpty) {
        if (!silent && context.mounted) _showCheckFailed(context);
        return;
      }

      final apkAsset = assets.firstWhere(
        (a) => (a['name'] as String).endsWith('.apk'),
        orElse: () => null,
      );
      if (apkAsset == null) {
        if (!silent && context.mounted) _showCheckFailed(context);
        return;
      }

      final downloadUrl = apkAsset['browser_download_url'] as String;
      final buildMatch = RegExp(r'(?:build)?(\d+)').firstMatch(latestTag);
      final latestBuild = int.tryParse(buildMatch?.group(1) ?? '0') ?? 0;

      if (latestBuild <= currentBuild) {
        if (!silent && context.mounted) _showUpToDate(context);
        return;
      }

      if (!force && await _isSnoozed(latestTag)) return;

      final highlights = _parseHighlights(body);

      if (context.mounted) {
        _showDialog(
          context,
          version: latestTag,
          displayName: releaseName,
          url: downloadUrl,
          highlights: highlights,
        );
      }
    } catch (_) {
      if (!silent && context.mounted) _showCheckFailed(context);
    }
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

  /// Turns a GitHub release body into a short, clean list of highlight
  /// lines for the popup — strips markdown bullet/heading noise and
  /// caps it at 4 lines so the dialog stays compact.
  static List<String> _parseHighlights(String body) {
    if (body.trim().isEmpty) return const [];
    final lines = body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((l) => l.replaceFirst(RegExp(r'^[-*•]\s*'), ''))
        .map((l) => l.replaceFirst(RegExp(r'^#{1,6}\s*'), ''))
        .where((l) => !l.startsWith('#'))
        .toList();
    return lines.take(4).toList();
  }

  static void _showDialog(
    BuildContext context, {
    required String version,
    required String displayName,
    required String url,
    required List<String> highlights,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (_) => _UpdateDialog(
        version: version,
        highlights: highlights,
        url: url,
        onDismiss: () => _snooze(version),
      ),
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
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
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
    return Positioned(
      bottom: 100,
      left: 24,
      right: 24,
      child: FadeTransition(
        opacity: _ctrl,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
              .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic)),
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF16161F).withOpacity(0.92),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(widget.icon, color: AurumTheme.gold, size: 18),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(widget.message,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ),
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
  final List<String> highlights;
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
  bool _downloading = false;
  bool _installing = false;
  String _status = '';
  late final AnimationController _entryCtrl;

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    _entryCtrl.forward();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    super.dispose();
  }

  Future<void> _downloadAndInstall() async {
    HapticFeedback.mediumImpact();
    setState(() {
      _downloading = true;
      _status = 'Downloading';
    });
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/aurum-update.apk';

      final oldFile = File(path);
      if (await oldFile.exists()) await oldFile.delete();

      final dio = Dio();
      await dio.download(
        widget.url,
        path,
        options: Options(
          headers: {'Accept': 'application/vnd.android.package-archive'},
          responseType: ResponseType.bytes,
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) setState(() => _progress = received / total);
        },
      );

      final file = File(path);
      final size = await file.length();
      if (size < 1024 * 1024) {
        setState(() {
          _downloading = false;
          _status = 'Download failed — please try again';
        });
        return;
      }

      setState(() {
        _installing = true;
        _status = 'Installing';
        _progress = 1.0;
      });
      HapticFeedback.lightImpact();
      await Future.delayed(const Duration(milliseconds: 350));
      await UpdateService.installApk(path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _downloading = false;
        _installing = false;
        _status = 'Something went wrong — check your connection';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic);
    return ScaleTransition(
      scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
      child: FadeTransition(
        opacity: curved,
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF121118).withOpacity(0.96),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white.withOpacity(0.07)),
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold.withOpacity(0.08),
                      blurRadius: 40,
                      spreadRadius: -8,
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Icon badge
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: AurumTheme.goldGradient,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: AurumTheme.gold.withOpacity(0.35),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.arrow_upward_rounded, color: Colors.black, size: 28),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'A new version of Aurum\nis ready',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Installs over your current app — nothing to uninstall.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),

                    if (widget.highlights.isNotEmpty && !_downloading) ...[
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.06)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('WHAT\'S NEW',
                                style: TextStyle(
                                  color: AurumTheme.gold.withOpacity(0.9),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                )),
                            const SizedBox(height: 10),
                            ...widget.highlights.map((h) => Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        margin: const EdgeInsets.only(top: 5),
                                        width: 5,
                                        height: 5,
                                        decoration: BoxDecoration(
                                          color: AurumTheme.gold,
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(h,
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(0.82),
                                              fontSize: 13,
                                              height: 1.4,
                                            )),
                                      ),
                                    ],
                                  ),
                                )),
                          ],
                        ),
                      ),
                    ],

                    if (_downloading) ...[
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Icon(
                            _installing ? Icons.settings_rounded : Icons.download_rounded,
                            color: AurumTheme.gold,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(_status,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.75),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              )),
                          const Spacer(),
                          if (_progress > 0 && _progress < 1.0)
                            Text('${(_progress * 100).toInt()}%',
                                style: TextStyle(
                                  color: AurumTheme.gold,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                )),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          height: 6,
                          child: _installing
                              ? const AurumM3Loader(height: 6, borderRadius: 8)
                              : TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0, end: _progress),
                                  duration: const Duration(milliseconds: 200),
                                  builder: (_, value, __) => LinearProgressIndicator(
                                    value: value,
                                    minHeight: 6,
                                    backgroundColor: Colors.white.withOpacity(0.08),
                                    valueColor: AlwaysStoppedAnimation(AurumTheme.gold),
                                  ),
                                ),
                        ),
                      ),
                    ],

                    if (!_status.startsWith('Something') && !_status.startsWith('Download failed'))
                      const SizedBox(height: 24)
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_status,
                            style: const TextStyle(
                              color: Color(0xFFE86B6B),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            )),
                      ),

                    if (!_downloading) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                widget.onDismiss();
                                Navigator.pop(context);
                              },
                              child: Text('Not now',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.45),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  )),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: _downloadAndInstall,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AurumTheme.gold,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 15),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: const Text('Update Now',
                                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
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
      ),
    );
  }
}
