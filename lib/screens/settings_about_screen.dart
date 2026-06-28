import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import '../theme/aurum_theme.dart';
import '../utils/constants.dart';
import '../services/update_service.dart';
import '../widgets/changelog_sheet.dart';

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

  void _showPrivacyPolicy() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.88,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        expand: false,
        builder: (_, ctrl) => Container(
          decoration: BoxDecoration(
            color: AurumTheme.bgCardOf(context),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AurumTheme.dividerOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: AurumTheme.gold.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.privacy_tip_rounded, color: AurumTheme.gold, size: 18),
                ),
                const SizedBox(width: 12),
                Text('Privacy Policy',
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 18, fontWeight: FontWeight.w700,
                  )),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: AurumTheme.textMutedOf(context)),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
            ),
            Divider(color: AurumTheme.dividerOf(context), height: 1),
            // Content
            Expanded(
              child: ListView(
                controller: ctrl,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                children: [
                  _policySection('Last updated: June 2026'),
                  _policyHeading('1. Introduction'),
                  _policyText(
                    'Aurum Music ("we", "our", or "us") is a personal music streaming application developed by Shivam Sharma. '
                    'This Privacy Policy explains how we handle your information when you use our app. '
                    'We are committed to protecting your privacy and ensuring transparency about our practices.'
                  ),
                  _policyHeading('2. Information We Collect'),
                  _policyText(
                    '• Google Account (name, email, profile photo) — only if you choose to sign in.\n'
                    '• Music preferences, liked songs, and playlists — stored locally on your device and optionally synced via Supabase.\n'
                    '• Recently played history — stored locally only.\n'
                    '• App settings (theme, equalizer, etc.) — stored locally only.'
                  ),
                  _policyHeading('3. Information We Do NOT Collect'),
                  _policyText(
                    'We do not collect, sell, or share any personally identifiable information with third parties. '
                    'We do not use advertising SDKs, analytics trackers, or crash reporting services. '
                    'No financial data, location data, contacts, or messages are ever accessed.'
                  ),
                  _policyHeading('4. Music Streaming'),
                  _policyText(
                    'Aurum Music streams audio content via a Cloudflare Worker proxy. '
                    'Song metadata and audio streams are fetched in real time and are not permanently stored on our servers. '
                    'We do not own the content streamed through this app.'
                  ),
                  _policyHeading('5. Third-Party Services'),
                  _policyText(
                    '• Google Sign-In: Subject to Google\'s Privacy Policy.\n'
                    '• Supabase: Used for optional cloud sync. Subject to Supabase\'s Privacy Policy.\n'
                    '• Cloudflare Workers: Used as an audio proxy. No user data is logged.'
                  ),
                  _policyHeading('6. Data Security'),
                  _policyText(
                    'All data stored locally on your device is protected by Android\'s built-in security. '
                    'We use industry-standard practices to protect any data transmitted over the network. '
                    'You may delete your data at any time by clearing the app\'s storage or uninstalling it.'
                  ),
                  _policyHeading('7. Children\'s Privacy'),
                  _policyText(
                    'Aurum Music is not directed at children under the age of 13. '
                    'We do not knowingly collect personal information from children.'
                  ),
                  _policyHeading('8. Changes to This Policy'),
                  _policyText(
                    'We may update this Privacy Policy from time to time. '
                    'Any changes will be reflected in the app\'s About section with an updated date.'
                  ),
                  _policyHeading('9. Contact'),
                  _policyText(
                    'If you have any questions about this Privacy Policy, you can reach us at:\n'
                    'Instagram: @shivam_shrma.01\n'
                    'Telegram: @mr_s_s01'
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _showRateDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Column(children: [
          const Text('🌟', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 8),
          Text('Enjoying Aurum?',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 20, fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
        ]),
        content: Text(
          'Star us on GitHub to show your support and help the project grow!',
          style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 14),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Maybe Later',
              style: TextStyle(color: AurumTheme.textMutedOf(context))),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AurumTheme.gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            ),
            onPressed: () {
              Navigator.pop(context);
              _launch('${AppConstants.github}/stargazers');
            },
            child: const Text('⭐ Star on GitHub', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _shareApp() {
    final version = _version.isEmpty ? '1.0.0' : _version;
    Share.share(
      '🎵 Check out Aurum Music — a premium music streaming app!\n\n'
      '✨ Features:\n'
      '• Stream millions of songs for free\n'
      '• Stunning gold-themed UI\n'
      '• Equalizer, bass boost & gapless playback\n'
      '• Offline downloads & smart playlists\n\n'
      '📲 Download Aurum Music v$version:\n'
      '${AppConstants.github}/releases/latest\n\n'
      '#AurumMusic #MusicStreaming',
      subject: 'Aurum Music — Premium Music Streaming',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'About'),
      body: ListView(
        physics: const BouncingScrollPhysics(),
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
            onTap: () { HapticFeedback.lightImpact(); UpdateService.checkForUpdate(context); },
          ),
          _actionTile(context,
            icon: Icons.history_rounded,
            title: 'Changelog',
            subtitle: 'What changed in recent versions',
            onTap: () { HapticFeedback.lightImpact(); ChangelogSheet.show(context); },
          ),

          _sectionLabel('LEGAL'),
          _actionTile(context,
            icon: Icons.privacy_tip_rounded,
            title: 'Privacy Policy',
            subtitle: 'How your data is handled',
            onTap: () { HapticFeedback.lightImpact(); _showPrivacyPolicy(); },
          ),

          _sectionLabel('COMMUNITY'),
          _actionTile(context,
            icon: Icons.star_rounded,
            title: 'Rate Aurum ⭐',
            subtitle: 'Show your support',
            iconColor: const Color(0xFFFFD700),
            onTap: () { HapticFeedback.lightImpact(); _showRateDialog(); },
          ),
          _actionTile(context,
            icon: Icons.share_rounded,
            title: 'Share Aurum',
            subtitle: 'Tell your friends about this app',
            onTap: () { HapticFeedback.lightImpact(); _shareApp(); },
          ),

          _sectionLabel('DEVELOPER'),
          _actionTile(context,
            customIcon: _instagramIcon(),
            title: 'Instagram',
            subtitle: '@shivam_shrma.01',
            onTap: () { HapticFeedback.lightImpact(); _launch(AppConstants.instagram); },
          ),
          _actionTile(context,
            customIcon: _telegramIcon(),
            title: 'Telegram',
            subtitle: '@mr_s_s01',
            onTap: () { HapticFeedback.lightImpact(); _launch(AppConstants.telegram); },
          ),
        ],
      ),
    );
  }

  Widget _instagramIcon() {
    return Container(
      width: 38, height: 38,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          colors: [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF), Color(0xFF515BD4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 18),
    );
  }

  Widget _telegramIcon() {
    return Container(
      width: 38, height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFF2AABEE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
    );
  }

  Widget _actionTile(
    BuildContext context, {
    IconData? icon,
    Widget? customIcon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    final color = iconColor ?? AurumTheme.gold;
    final leading = customIcon ?? Container(
      width: 38, height: 38,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: 18),
    );

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
        leading: leading,
        title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
        trailing: Icon(Icons.arrow_forward_ios_rounded, color: AurumTheme.textMutedOf(context), size: 14),
      ),
    );
  }

  Widget _policySection(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(text, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
  );

  Widget _policyHeading(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 6),
    child: Text(text, style: TextStyle(
      color: AurumTheme.textPrimaryOf(context),
      fontSize: 15, fontWeight: FontWeight.w700,
    )),
  );

  Widget _policyText(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: TextStyle(
      color: AurumTheme.textSecondaryOf(context),
      fontSize: 13, height: 1.6,
    )),
  );
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
