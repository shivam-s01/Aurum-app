import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateService {
  static const _repo = 'shivam-s01/Aurum-app';
  static const _apiUrl = 'https://api.github.com/repos/$_repo/releases/latest';
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
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.system_update_rounded, color: Color(0xFFD4AF37), size: 24),
          SizedBox(width: 10),
          Text('Update Available', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Version $version is ready!',
              style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
          const SizedBox(height: 8),
          Text('Install over existing app — no uninstall needed.',
              style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: Text('Later', style: TextStyle(color: Colors.white.withOpacity(0.4)))),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD4AF37),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Download', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
