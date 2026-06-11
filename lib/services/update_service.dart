import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:android_intent_plus/android_intent.dart';

class UpdateService {
  static const _repo = 'shivam-s01/Aurum-app';
  static const _apiUrl = 'https://api.github.com/repos/$_repo/releases/latest';
  static const _channel = MethodChannel('com.aurum.music/media_store');
  static int _currentBuild = 0;

  static void setCurrentBuild(int build) => _currentBuild = build;

  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final response = await http.get(Uri.parse(_apiUrl),
          headers: {'Accept': 'application/vnd.github.v3+json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body);
      final latestTag = data['tag_name'] as String? ?? '';
      final assets = data['assets'] as List<dynamic>? ?? [];
      if (assets.isEmpty) return;
      final apkAsset = assets.firstWhere(
        (a) => (a['name'] as String).endsWith('.apk'),
        orElse: () => null,
      );
      if (apkAsset == null) return;
      final downloadUrl = apkAsset['browser_download_url'] as String;
      final buildMatch = RegExp(r'build(\d+)').firstMatch(latestTag);
      final latestBuild = int.tryParse(buildMatch?.group(1) ?? '0') ?? 0;
      if (latestBuild <= _currentBuild) return;
      if (context.mounted) _showDialog(context, latestTag, downloadUrl);
    } catch (_) {}
  }

  static void _showDialog(BuildContext context, String version, String url) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(version: version, url: url),
    );
  }

  static Future<void> installApk(String path) async {
    try {
      await _channel.invokeMethod('installApk', {'path': path});
    } catch (_) {
      final intent = AndroidIntent(
        action: 'action_view',
        data: 'file://$path',
        type: 'application/vnd.android.package-archive',
        flags: [0x10000000, 0x00000001],
      );
      await intent.launch();
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  final String version;
  final String url;
  const _UpdateDialog({required this.version, required this.url});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0;
  bool _downloading = false;
  String _status = '';

  Future<void> _downloadAndInstall() async {
    setState(() { _downloading = true; _status = 'Downloading...'; });
    try {
      final dir = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final path = '${dir.path}/aurum-update.apk';
      final dio = Dio();
      await dio.download(
        widget.url,
        path,
        onReceiveProgress: (received, total) {
          if (total > 0) setState(() => _progress = received / total);
        },
      );
      setState(() { _status = 'Installing...'; _progress = 1.0; });
      await Future.delayed(const Duration(milliseconds: 500));
      await UpdateService.installApk(path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() { _downloading = false; _status = 'Failed. Try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.system_update_rounded, color: Color(0xFFD4AF37), size: 24),
        SizedBox(width: 10),
        Text('Update Available', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Version ${widget.version} is ready!',
            style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
        const SizedBox(height: 8),
        Text('Install over existing app — no uninstall needed.',
            style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
        if (_downloading) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(Color(0xFFD4AF37)),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _progress > 0 && _progress < 1.0 ? '$_status ${(_progress * 100).toInt()}%' : _status,
            style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
          ),
        ],
      ]),
      actions: _downloading ? [] : [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Later', style: TextStyle(color: Colors.white.withOpacity(0.4))),
        ),
        ElevatedButton(
          onPressed: _downloadAndInstall,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFD4AF37),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Update Now', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
