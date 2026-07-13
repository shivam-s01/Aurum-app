import 'package:aurum_music/widgets/aurum_loader.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../l10n/generated/app_localizations.dart';

class SettingsStorageScreen extends StatefulWidget {
  const SettingsStorageScreen({super.key});
  @override
  State<SettingsStorageScreen> createState() => _SettingsStorageScreenState();
}

class _SettingsStorageScreenState extends State<SettingsStorageScreen> {
  double _maxSongCache   = 500.0;
  double _maxImageCache  = 100.0;
  int _downloadedSize    = 0;
  int _songCacheUsed     = 0;
  int _imageCacheUsed    = 0;
  bool _loading          = true;

  // New
  String _downloadQuality    = '320kbps';
  bool   _autoDownloadLiked  = false;
  bool   _downloadWifiOnly   = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p        = await SharedPreferences.getInstance();
    final appDir   = await getApplicationDocumentsDirectory();
    final cacheDir = await getTemporaryDirectory();

    int downloadSize   = 0;
    int songCacheSize  = 0;
    int imageCacheSize = 0;

    try {
      final downloadDir = Directory('${appDir.path}/downloads');
      if (await downloadDir.exists()) downloadSize = await _dirSize(downloadDir);
      final songCache = Directory('${cacheDir.path}/song_cache');
      if (await songCache.exists()) songCacheSize = await _dirSize(songCache);
      final imgCache = Directory('${cacheDir.path}/image_cache');
      if (await imgCache.exists()) imageCacheSize = await _dirSize(imgCache);
    } catch (_) {}

    setState(() {
      _maxSongCache        = p.getDouble('max_song_cache')   ?? 500.0;
      _maxImageCache       = p.getDouble('max_image_cache')  ?? 100.0;
      _downloadQuality     = p.getString('download_quality') ?? '320kbps';
      _autoDownloadLiked   = p.getBool('auto_download_liked')  ?? false;
      _downloadWifiOnly    = p.getBool('download_wifi_only')   ?? true;
      _downloadedSize  = downloadSize;
      _songCacheUsed   = songCacheSize;
      _imageCacheUsed  = imageCacheSize;
      _loading         = false;
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

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool)   await p.setBool(key, value);
    if (value is double) await p.setDouble(key, value);
    if (value is String) await p.setString(key, value);
  }

  Future<void> _clearDir(String subPath) async {
    final cacheDir = await getTemporaryDirectory();
    final dir = Directory('${cacheDir.path}/$subPath');
    if (await dir.exists()) await dir.delete(recursive: true);
    _load();
  }

  Future<void> _clearDownloads() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/downloads');
    if (await dir.exists()) await dir.delete(recursive: true);
    _load();
  }

  void _confirmClear(BuildContext context, String title, VoidCallback onConfirm) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.ssClearConfirmTitle(title),
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text(l10n.ssClearConfirmBody,
          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
            child: Text(l10n.ssCancel, style: TextStyle(color: AurumTheme.textSecondaryOf(context)))),
          TextButton(
            onPressed: () { Navigator.pop(context); onConfirm(); },
            child: Text(l10n.ssClear, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, l10n.settingsStorage),
      body: _loading
          ? const Center(child: AurumMorphLoader(size: 56))
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [

                // ── DOWNLOADS ─────────────────────────────────────────────
                _sectionLabel(l10n.ssDownloads),
                _storageCard(context,
                  title: l10n.ssDownloadedSongs,
                  used: _fmt(_downloadedSize),
                  clearLabel: l10n.ssClearAllDownloads,
                  onClear: () { HapticFeedback.mediumImpact(); _confirmClear(context, l10n.ssAllDownloadsTitle, _clearDownloads); },
                ),

                // Download Quality
                _dropdownTile(context,
                  icon: Icons.high_quality_rounded,
                  title: l10n.ssDownloadQuality,
                  subtitle: l10n.ssDownloadQualitySubtitle,
                  value: _downloadQuality,
                  options: const ['96kbps', '128kbps', '320kbps'],
                  onChanged: (v) { setState(() => _downloadQuality = v!); _save('download_quality', v!); },
                ),

                // Auto-download liked songs
                _switchTile(context,
                  icon: Icons.favorite_rounded,
                  title: l10n.ssAutoDownloadLiked,
                  subtitle: l10n.ssAutoDownloadLikedSubtitle,
                  value: _autoDownloadLiked,
                  onChanged: (v) { setState(() => _autoDownloadLiked = v); _save('auto_download_liked', v); },
                ),

                // WiFi only
                _switchTile(context,
                  icon: Icons.wifi_rounded,
                  title: l10n.ssWifiOnly,
                  subtitle: l10n.ssWifiOnlySubtitle,
                  value: _downloadWifiOnly,
                  onChanged: (v) { setState(() => _downloadWifiOnly = v); _save('download_wifi_only', v); },
                ),

                // ── SONG CACHE ─────────────────────────────────────────────
                _sectionLabel(l10n.ssSongCache),
                _cacheSliderCard(context,
                  title: l10n.ssMaxSongCacheSize,
                  value: _maxSongCache,
                  max: 2000,
                  usedBytes: _songCacheUsed,
                  displayMax: _maxSongCache >= 1000
                      ? '${(_maxSongCache / 1024).toStringAsFixed(1)}GB'
                      : '${_maxSongCache.toInt()}MB',
                  onChanged: (v) async {
                    setState(() => _maxSongCache = v);
                    await _save('max_song_cache', v);
                  },
                  onClear: () { HapticFeedback.mediumImpact(); _confirmClear(context, l10n.ssSongCacheTitle, () => _clearDir('song_cache')); },
                  clearLabel: l10n.ssClearSongCache,
                ),

                // ── IMAGE CACHE ────────────────────────────────────────────
                _sectionLabel(l10n.ssImageCache),
                _cacheSliderCard(context,
                  title: l10n.ssMaxImageCacheSize,
                  value: _maxImageCache,
                  max: 500,
                  usedBytes: _imageCacheUsed,
                  displayMax: '${_maxImageCache.toInt()}MB',
                  onChanged: (v) async {
                    setState(() => _maxImageCache = v);
                    await _save('max_image_cache', v);
                    PaintingBinding.instance.imageCache.maximumSizeBytes =
                        (v * 1024 * 1024).toInt();
                  },
                  onClear: () { HapticFeedback.mediumImpact(); _confirmClear(context, l10n.ssImageCacheTitle, () => _clearDir('image_cache')); },
                  clearLabel: l10n.ssClearImageCache,
                ),
              ],
            ),
    );
  }

  // ── Cards ─────────────────────────────────────────────────────────────────
  Widget _storageCard(BuildContext context, {
    required String title,
    required String used,
    required String clearLabel,
    required VoidCallback onClear,
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
            Text(used, style: const TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
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
              child: Center(child: Text(clearLabel,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600))),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _cacheSliderCard(BuildContext context, {
    required String title,
    required double value,
    required double max,
    required int usedBytes,
    required String displayMax,
    required ValueChanged<double> onChanged,
    required VoidCallback onClear,
    required String clearLabel,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final usedMB   = usedBytes / (1024 * 1024);
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
            Text(displayMax, style: const TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
          Slider(value: value, min: 0, max: max, divisions: 20, onChanged: onChanged),
          Row(children: [
            Text(l10n.ssUsedLabel(_fmt(usedBytes)),
              style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12)),
            const Spacer(),
            Text(l10n.ssMaxLabel(displayMax),
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AurumM3Loader(height: 6, borderRadius: 4),
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
              child: Center(child: Text(clearLabel,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600))),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
AppBar _appBar(BuildContext context, String title) => AppBar(
  backgroundColor: AurumTheme.bgOf(context),
  elevation: 0, scrolledUnderElevation: 0,
  leading: IconButton(
    icon: Icon(Icons.arrow_back_ios_new_rounded, color: AurumTheme.textPrimaryOf(context), size: 20),
    onPressed: () => Navigator.pop(context),
  ),
  title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w600)),
);

Widget _sectionLabel(String label) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
  child: Text(label, style: const TextStyle(color: AurumTheme.gold, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
);

Widget _switchTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required bool value, required ValueChanged<bool> onChanged,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
    ),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: value ? AurumTheme.gold.withOpacity(0.12) : AurumTheme.bgOf(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: value ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 18),
      ),
      title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Switch(value: value, onChanged: onChanged, activeColor: AurumTheme.gold),
    ),
  );
}

Widget _dropdownTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required String value, required List<String> options, required ValueChanged<String?> onChanged,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
    ),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: AurumTheme.gold.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: AurumTheme.gold, size: 18),
      ),
      title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: DropdownButton<String>(
        value: value,
        underline: const SizedBox(),
        dropdownColor: AurumTheme.bgCardOf(context),
        style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600),
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: AurumTheme.gold, size: 18),
        items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
        onChanged: onChanged,
      ),
    ),
  );
}
