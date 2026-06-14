import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../theme/aurum_theme.dart';
import '../utils/constants.dart';
import '../services/update_service.dart';

class SettingsAboutScreen extends StatefulWidget {
  const SettingsAboutScreen({super.key});
  @override
  State<SettingsAboutScreen> createState() => _SettingsAboutScreenState();
}

class _SettingsAboutScreenState extends State<SettingsAboutScreen> {
  String _version = '';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _version = info.version;
      _buildNumber = info.buildNumber;
    });
  }

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'About'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // App identity card
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AurumTheme.gold.withOpacity(0.2), width: 0.5),
              gradient: LinearGradient(
                colors: [AurumTheme.gold.withOpacity(0.06), Colors.transparent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AurumTheme.gold.withOpacity(0.3)),
                ),
                child: const Icon(Icons.music_note_rounded, color: AurumTheme.gold, size: 28),
              ),
              const SizedBox(width: 16),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Aurum Music',
                  style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  _version.isEmpty ? 'Loading...' : 'v$_version (build $_buildNumber)',
                  style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
                ),
              ]),
            ]),
          ),

          _sectionLabel('UPDATE'),
          _actionTile(context,
            icon: Icons.system_update_rounded,
            title: 'Check for Update',
            subtitle: 'See if a new version is available',
            onTap: () => UpdateService.checkForUpdate(context),
          ),
          _actionTile(context,
            icon: Icons.history_rounded,
            title: 'Changelog',
            subtitle: 'What changed in recent versions',
            onTap: () => _launch('${AppConstants.github}/releases'),
          ),

          _sectionLabel('LEGAL'),
          _actionTile(context,
            icon: Icons.privacy_tip_rounded,
            title: 'Privacy Policy',
            subtitle: 'How your data is handled',
            onTap: () => _launch('${AppConstants.github}#privacy'),
          ),

          _sectionLabel('COMMUNITY'),
          _actionTile(context,
            icon: Icons.star_rounded,
            title: 'Rate Aurum ⭐',
            subtitle: 'Drop a star on GitHub',
            iconColor: const Color(0xFFFFD700),
            onTap: () => _launch('${AppConstants.github}/stargazers'),
          ),
          _actionTile(context,
            icon: Icons.share_rounded,
            title: 'Share Aurum',
            subtitle: 'Tell your friends about this app',
            onTap: () => _launch(AppConstants.github),
          ),

          _sectionLabel('DEVELOPER'),
          _actionTile(context,
            icon: Icons.camera_alt_rounded,
            title: 'Instagram',
            subtitle: '@shivam_shrma.01',
            iconColor: const Color(0xFFE1306C),
            onTap: () => _launch(AppConstants.instagram),
          ),
          _actionTile(context,
            icon: Icons.send_rounded,
            title: 'Telegram',
            subtitle: '@mr_s_s01',
            iconColor: const Color(0xFF2AABEE),
            onTap: () => _launch(AppConstants.telegram),
          ),
          _actionTile(context,
            icon: Icons.code_rounded,
            title: 'GitHub',
            subtitle: 'shivam-s01/Aurum-app',
            onTap: () => _launch(AppConstants.github),
          ),
        ],
      ),
    );
  }

  Widget _actionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    final color = iconColor ?? AurumTheme.gold;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
        trailing: Icon(Icons.arrow_forward_ios_rounded, color: AurumTheme.textMutedOf(context), size: 14),
      ),
    );
  }
}

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
