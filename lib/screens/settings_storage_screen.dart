import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';

class SettingsStorageScreen extends StatefulWidget {
  const SettingsStorageScreen({super.key});
  @override
  State<SettingsStorageScreen> createState() => _SettingsStorageScreenState();
}

class _SettingsStorageScreenState extends State<SettingsStorageScreen> {
  double _maxSongCache = 500.0; // MB
  double _maxImageCache = 100.0; // MB
  int _downloadedSize = 0; // bytes
  int _songCacheUsed = 0;
  int _imageCacheUsed = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = await getTemporaryDirectory();

    int downloadSize = 0;
    int songCacheSize = 0;
    int imageCacheSize = 0;

    try {
      final downloadDir = Directory('${appDir.path}/downloads');
      if (await downloadDir.exists()) {
        downloadSize = await _dirSize(downloadDir);
      }
      final songCache = Directory('${cacheDir.path}/song_cache');
      if (await songCache.exists()) songCacheSize = await _dirSize(songCache);
      final imgCache = Directory('${cacheDir.path}/image_cache');
      if (await imgCache.exists()) imageCacheSize = await _dirSize(imgCache);
    } catch (_) {}

    setState(() {
      _maxSongCache = p.getDouble('max_song_cache') ?? 500.0;
      _maxImageCache = p.getDouble('max_image_cache') ?? 100.0;
      _downloadedSize = downloadSize;
      _songCacheUsed = songCacheSize;
      _imageCacheUsed = imageCacheSize;
      _loading = false;
    });
  }

  Future<int> _dirSize(Directory dir) async {
    int total = 0;
    try {
      await for (final f in dir.list(recursive: true)) {
        if (f is File) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  Future<void> _clearDir(String subPath, VoidCallback onDone) async {
    final cacheDir = await getTemporaryDirectory();
    final dir = Directory('${cacheDir.path}/$subPath');
    if (await dir.exists()) await dir.delete(recursive: true);
    onDone();
    _load();
  }

  Future<void> _clearDownloads() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/downloads');
    if (await dir.exists()) await dir.delete(recursive: true);
    _load();
  }

  void _confirmClear(BuildContext context, String title, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Clear $title?',
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text('This cannot be undone.',
          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: AurumTheme.textSecondaryOf(context)))),
          TextButton(
            onPressed: () { Navigator.pop(context); onConfirm(); },
            child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'Storage'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                // ── Downloads ──
                _sectionLabel('📥 DOWNLOADS'),
                _storageCard(
                  context,
                  title: 'Downloaded Songs',
                  used: _fmt(_downloadedSize),
                  isReadOnly: true,
                  onClear: () => _confirmClear(context, 'All Downloads', _clearDownloads),
                  fraction: 0,
                ),
                // ── Song Cache ──
                _sectionLabel('🎵 SONG CACHE'),
                _cacheSliderCard(
                  context,
                  title: 'Max Song Cache Size',
                  value: _maxSongCache,
                  max: 2000,
                  usedBytes: _songCacheUsed,
                  displayMax: '${(_maxSongCache / 1024).toStringAsFixed(1)}GB',
                  onChanged: (v) async {
                    setState(() => _maxSongCache = v);
                    final p = await SharedPreferences.getInstance();
                    await p.setDouble('max_song_cache', v);
                  },
                  onClear: () => _confirmClear(context, 'Song Cache', () {}),
                  cacheSubPath: 'song_cache',
                ),
                // ── Image Cache ──
                _sectionLabel('🖼️ IMAGE CACHE'),
                _cacheSliderCard(
                  context,
                  title: 'Max Image Cache Size',
                  value: _maxImageCache,
                  max: 500,
                  usedBytes: _imageCacheUsed,
                  displayMax: '${_maxImageCache.toInt()}MB',
                  onChanged: (v) async {
                    setState(() => _maxImageCache = v);
                    final p = await SharedPreferences.getInstance();
                    await p.setDouble('max_image_cache', v);
                  },
                  onClear: () => _confirmClear(context, 'Image Cache', () {}),
                  cacheSubPath: 'image_cache',
                ),
              ],
            ),
    );
  }

  Widget _storageCard(
    BuildContext context, {
    required String title,
    required String used,
    required bool isReadOnly,
    required VoidCallback onClear,
    required double fraction,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title,
              style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500))),
            Text(used, style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onClear,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
              ),
              child: const Center(
                child: Text('Clear All Downloads',
                  style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _cacheSliderCard(
    BuildContext context, {
    required String title,
    required double value,
    required double max,
    required int usedBytes,
    required String displayMax,
    required ValueChanged<double> onChanged,
    required VoidCallback onClear,
    required String cacheSubPath,
  }) {
    final usedMB = usedBytes / (1024 * 1024);
    final fraction = (usedMB / (max == 0 ? 1 : max)).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title,
              style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500))),
            Text(displayMax, style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
          Slider(value: value, min: 0, max: max, divisions: 20, onChanged: onChanged),
          // Used/Total bar
          Row(children: [
            Text('Used: ${_fmt(usedBytes)}',
              style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12)),
            const Spacer(),
            Text('Max: $displayMax',
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              backgroundColor: AurumTheme.bgOf(context),
              valueColor: AlwaysStoppedAnimation<Color>(AurumTheme.gold),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onClear,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
              ),
              child: Center(
                child: Text('Clear ${cacheSubPath == 'song_cache' ? 'Song' : 'Image'} Cache',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

AppBar _appBar(BuildContext context, String title) {
  return AppBar(
    backgroundColor: AurumTheme.bgOf(context),
    elevation: 0, scrolledUnderElevation: 0,
    leading: IconButton(
      icon: Icon(Icons.arrow_back_ios_new_rounded, color: AurumTheme.textPrimaryOf(context), size: 20),
      onPressed: () => Navigator.pop(context),
    ),
    title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w600)),
  );
}

Widget _sectionLabel(String label) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
  child: Text(label, style: const TextStyle(color: AurumTheme.gold, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
);
