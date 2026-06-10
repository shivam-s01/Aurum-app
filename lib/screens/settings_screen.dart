import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
        physics: const BouncingScrollPhysics(),
        slivers: [
          _buildAppBar(context),
          SliverToBoxAdapter(
            child: Column(
              children: [
                _buildThemeSection(context),
                _buildPlayerSection(context),
                _buildAudioSection(context),
                _buildDownloadsSection(context),
                _buildCacheSection(context),
                _buildAboutSection(context),
                const SizedBox(height: 120),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: AurumTheme.bgOf(context),
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_rounded,
            color: AurumTheme.textPrimaryOf(context), size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        'Settings',
        style: TextStyle(
          color: AurumTheme.textPrimaryOf(context),
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  // ── Look & Feel ───────────────────────────────────────────────────────────

  Widget _buildThemeSection(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, theme, _) {
        return _Section(
          title: 'Look & Feel',
          icon: Icons.palette_outlined,
          children: [
            _SectionCard(
              children: [
                // Theme chooser
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Theme',
                        style: TextStyle(
                          color: AurumTheme.textSecondaryOf(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _ThemeOption(
                            label: 'Dark',
                            icon: Icons.dark_mode_outlined,
                            isSelected:
                                theme.mode == AurumThemeMode.dark,
                            onTap: () =>
                                theme.setMode(AurumThemeMode.dark),
                          ),
                          const SizedBox(width: 10),
                          _ThemeOption(
                            label: 'Light',
                            icon: Icons.light_mode_outlined,
                            isSelected:
                                theme.mode == AurumThemeMode.light,
                            onTap: () =>
                                theme.setMode(AurumThemeMode.light),
                          ),
                          const SizedBox(width: 10),
                          _ThemeOption(
                            label: 'AMOLED',
                            icon: Icons.brightness_1_outlined,
                            isSelected:
                                theme.mode == AurumThemeMode.amoled,
                            onTap: () => theme
                                .setMode(AurumThemeMode.amoled),
                          ),
                          const SizedBox(width: 10),
                          _ThemeOption(
                            label: 'System',
                            icon: Icons.settings_system_daydream_outlined,
                            isSelected:
                                theme.mode == AurumThemeMode.system,
                            onTap: () =>
                                theme.setMode(AurumThemeMode.system),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(
                    height: 1,
                    color: AurumTheme.dividerOf(context)),
                _SettingsTile(
                  icon: Icons.brightness_1_rounded,
                  iconColor: Colors.black,
                  title: 'AMOLED Black',
                  subtitle: 'Pure black for OLED displays',
                  trailing: Switch.adaptive(
                    value: theme.isAmoled,
                    onChanged: (v) => theme.setMode(
                        v ? AurumThemeMode.amoled : AurumThemeMode.dark),
                    activeColor: AurumTheme.gold,
                  ),
                ),
                _SettingsTile(
                  icon: Icons.color_lens_outlined,
                  iconColor: AurumTheme.gold,
                  title: 'Dynamic Colors',
                  subtitle: 'Adapt to album artwork (coming soon)',
                  trailing: Switch.adaptive(
                    value: false,
                    onChanged: null,
                    activeColor: AurumTheme.gold,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // ── Player Settings ───────────────────────────────────────────────────────

  Widget _buildPlayerSection(BuildContext context) {
    return _Section(
      title: 'Player',
      icon: Icons.play_circle_outlined,
      children: [
        _SectionCard(
          children: [
            _SettingsTile(
              icon: Icons.replay_rounded,
              title: 'Auto Play',
              subtitle: 'Continue playing similar songs',
              trailing: Switch.adaptive(
                value: true,
                onChanged: (_) {},
                activeColor: AurumTheme.gold,
              ),
            ),
            _SettingsTile(
              icon: Icons.skip_next_rounded,
              title: 'Crossfade',
              subtitle: 'Smooth transition between songs',
              trailing: Switch.adaptive(
                value: false,
                onChanged: null,
                activeColor: AurumTheme.gold,
              ),
            ),
            _SettingsTile(
              icon: Icons.lock_outline_rounded,
              title: 'Lock Screen Controls',
              subtitle: 'Show media controls on lock screen',
              trailing: Switch.adaptive(
                value: true,
                onChanged: (_) {},
                activeColor: AurumTheme.gold,
              ),
            ),
            _SettingsTile(
              icon: Icons.notifications_outlined,
              title: 'Notification Controls',
              subtitle: 'Media controls in notification bar',
              trailing: Switch.adaptive(
                value: true,
                onChanged: (_) {},
                activeColor: AurumTheme.gold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Audio ─────────────────────────────────────────────────────────────────

  Widget _buildAudioSection(BuildContext context) {
    return _Section(
      title: 'Audio Quality',
      icon: Icons.graphic_eq_rounded,
      children: [
        _SectionCard(
          children: [
            _SettingsTile(
              icon: Icons.high_quality_rounded,
              iconColor: AurumTheme.gold,
              title: 'Stream Quality',
              subtitle: 'High (320kbps)',
              trailing: Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onTap: () {},
            ),
            _SettingsTile(
              icon: Icons.download_rounded,
              title: 'Download Quality',
              subtitle: 'Original quality',
              trailing: Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onTap: () {},
            ),
            _SettingsTile(
              icon: Icons.tune_rounded,
              title: 'Equalizer',
              subtitle: 'Adjust sound frequencies',
              trailing: Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }

  // ── Downloads ─────────────────────────────────────────────────────────────

  Widget _buildDownloadsSection(BuildContext context) {
    return _Section(
      title: 'Downloads',
      icon: Icons.download_outlined,
      children: [
        _SectionCard(
          children: [
            _SettingsTile(
              icon: Icons.wifi_rounded,
              title: 'Download over WiFi only',
              subtitle: 'Saves mobile data',
              trailing: Switch.adaptive(
                value: true,
                onChanged: (_) {},
                activeColor: AurumTheme.gold,
              ),
            ),
            _SettingsTile(
              icon: Icons.folder_outlined,
              title: 'Download Location',
              subtitle: 'Internal Storage / Music',
              trailing: Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }

  // ── Cache ─────────────────────────────────────────────────────────────────

  Widget _buildCacheSection(BuildContext context) {
    return _Section(
      title: 'Storage & Cache',
      icon: Icons.storage_outlined,
      children: [
        _SectionCard(
          children: [
            _SettingsTile(
              icon: Icons.cleaning_services_outlined,
              iconColor: Colors.orangeAccent,
              title: 'Clear Cache',
              subtitle: 'Free up space',
              trailing: Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onTap: () => _showClearCacheDialog(context),
            ),
            _SettingsTile(
              icon: Icons.backup_outlined,
              title: 'Backup & Restore',
              subtitle: 'Playlists, favourites, settings',
              trailing: Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }

  // ── About ─────────────────────────────────────────────────────────────────

  Widget _buildAboutSection(BuildContext context) {
    return _Section(
      title: 'About',
      icon: Icons.info_outline_rounded,
      children: [
        _SectionCard(
          children: [
            _SettingsTile(
              icon: Icons.music_note_rounded,
              iconColor: AurumTheme.gold,
              title: AppConstants.appName,
              subtitle: 'Version ${AppConstants.appVersion}',
            ),
            _SettingsTile(
              icon: Icons.code_rounded,
              title: 'Developed by',
              subtitle: 'Shivam Sharma (S.S Developer)',
            ),
            _SettingsTile(
              icon: Icons.link_rounded,
              title: 'GitHub',
              subtitle: 'Source code',
              trailing: Icon(Icons.open_in_new_rounded,
                  color: AurumTheme.textMutedOf(context), size: 16),
              onTap: () {},
            ),
            _SettingsTile(
              icon: Icons.telegram_rounded,
              iconColor: const Color(0xFF2AABEE),
              title: 'Telegram',
              subtitle: '@mr_s_s01',
              trailing: Icon(Icons.open_in_new_rounded,
                  color: AurumTheme.textMutedOf(context), size: 16),
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }

  void _showClearCacheDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgElevatedOf(context),
        title: Text('Clear Cache',
            style:
                TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: Text(
          'This will remove cached images and data. Your downloads and favourites won\'t be affected.',
          style: TextStyle(
              color: AurumTheme.textSecondaryOf(context),
              fontSize: 13,
              height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: TextStyle(
                    color: AurumTheme.textMutedOf(context))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Clear',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

// ── Shared Widgets ────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon,
                  color: AurumTheme.gold.withOpacity(0.7),
                  size: 16),
              const SizedBox(width: 8),
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: AurumTheme.gold.withOpacity(0.7),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final List<Widget> children;
  const _SectionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Column(
        children: children
            .asMap()
            .entries
            .map((e) {
              final child = e.value;
              if (e.key == children.length - 1) return child;
              return Column(
                children: [
                  child,
                  Divider(
                    height: 1,
                    indent: 56,
                    color: AurumTheme.dividerOf(context),
                  ),
                ],
              );
            })
            .toList(),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: (iconColor ?? AurumTheme.textMutedOf(context))
                    .withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: iconColor ??
                    AurumTheme.textSecondaryOf(context),
                size: 18,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? AurumTheme.gold.withOpacity(0.15)
                : AurumTheme.bgElevatedOf(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? AurumTheme.gold.withOpacity(0.5)
                  : AurumTheme.dividerOf(context),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isSelected
                    ? AurumTheme.gold
                    : AurumTheme.textMutedOf(context),
                size: 18,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? AurumTheme.gold
                      : AurumTheme.textMutedOf(context),
                  fontSize: 10,
                  fontWeight: isSelected
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
