import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/theme_provider.dart';
import '../theme/aurum_theme.dart';
import '../utils/constants.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            floating: true,
            snap: true,
            backgroundColor: AurumTheme.bgOf(context),
            automaticallyImplyLeading: false,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              title: ShaderMask(
                shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
                child: const Text('Settings', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: -0.5)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('APPEARANCE'),
                Consumer<ThemeProvider>(
                  builder: (context, tp, _) => Column(children: [
                    _themeTile(context, tp, Icons.dark_mode_rounded, 'Dark', 'Easy on the eyes', AurumThemeMode.dark),
                    _themeTile(context, tp, Icons.contrast_rounded, 'AMOLED Black', 'Pure black, saves battery', AurumThemeMode.amoled),
                    _themeTile(context, tp, Icons.light_mode_rounded, 'Light', 'Clean and minimal', AurumThemeMode.light),
                    _themeTile(context, tp, Icons.phone_android_rounded, 'System Default', 'Follow your phone theme', AurumThemeMode.system),
                  ]),
                ),
                const SizedBox(height: 8),
                Divider(color: AurumTheme.dividerOf(context), height: 1, indent: 16, endIndent: 16),
                _sectionTitle('CONNECT'),
                _linkTile(context, Icons.camera_alt_rounded, 'Instagram', '@shivam_shrma.01', AppConstants.instagram, const Color(0xFFE1306C)),
                _linkTile(context, Icons.send_rounded, 'Telegram', '@mr_s_s01', AppConstants.telegram, const Color(0xFF2AABEE)),
                _linkTile(context, Icons.code_rounded, 'GitHub', 'shivam-s01/Aurum-app', AppConstants.github, AurumTheme.textSecondary),
                const SizedBox(height: 8),
                Divider(color: AurumTheme.dividerOf(context), height: 1, indent: 16, endIndent: 16),
                _sectionTitle('ABOUT'),
                ListTile(
                  leading: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(color: AurumTheme.bgSurfaceOf(context), borderRadius: BorderRadius.circular(10)),
                    child: Icon(Icons.music_note_rounded, color: AurumTheme.gold, size: 20),
                  ),
                  title: Text('Aurum Music', style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14)),
                  subtitle: Text('Version ${AppConstants.appVersion}', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
                ),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(title, style: const TextStyle(color: AurumTheme.gold, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
  );

  Widget _themeTile(BuildContext context, ThemeProvider tp, IconData icon, String label, String sub, AurumThemeMode mode) {
    final selected = tp.mode == mode;
    return ListTile(
      onTap: () => tp.setMode(mode),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: selected ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(10),
          border: selected ? Border.all(color: AurumTheme.gold.withOpacity(0.5)) : null,
        ),
        child: Icon(icon, color: selected ? AurumTheme.gold : AurumTheme.textSecondaryOf(context), size: 20),
      ),
      title: Text(label, style: TextStyle(color: selected ? AurumTheme.gold : AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      subtitle: Text(sub, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined, color: selected ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 20),
    );
  }

  Widget _linkTile(BuildContext context, IconData icon, String label, String sub, String url, Color color) {
    return ListTile(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(label, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14)),
      subtitle: Text(sub, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Icon(Icons.arrow_forward_ios_rounded, color: AurumTheme.textMutedOf(context), size: 14),
    );
  }
}
