import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../services/audio_prefs.dart';
import '../providers/player_provider.dart';

class SettingsNotificationsScreen extends StatefulWidget {
  const SettingsNotificationsScreen({super.key});
  @override
  State<SettingsNotificationsScreen> createState() => _SettingsNotificationsScreenState();
}

class _SettingsNotificationsScreenState extends State<SettingsNotificationsScreen> {
  bool   _showMediaNotif      = true;
  bool   _showArtworkInNotif  = true;
  String _notifStyle          = 'Expanded';

  // New
  bool _showPrevButton = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _showMediaNotif     = p.getBool('show_media_notif')    ?? true;
      _showArtworkInNotif = p.getBool('show_artwork_notif')  ?? true;
      _notifStyle         = p.getString('notif_style')       ?? 'Expanded';
      _showPrevButton     = p.getBool('notif_show_prev')     ?? true;
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool)   await p.setBool(key, value);
    if (value is String) await p.setString(key, value);
    // Reload live so notification updates immediately
    await AudioPrefs.load();
    try {
      final handler = context.read<PlayerProvider>().handler;
      await handler.customAction('reloadSettings');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'Notifications'),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [

          // ── PLAYER NOTIFICATION ───────────────────────────────────────
          _sectionLabel('🔔 PLAYER NOTIFICATION'),
          _switchTile(context,
            icon: Icons.notifications_rounded,
            title: 'Show Media Notification',
            subtitle: 'Display player in notification bar',
            value: _showMediaNotif,
            onChanged: (v) { setState(() => _showMediaNotif = v); _save('show_media_notif', v); AudioPrefs.showMediaNotif = v; },
          ),
          _switchTile(context,
            icon: Icons.image_rounded,
            title: 'Show Song Artwork',
            subtitle: 'Display album art in notification',
            value: _showArtworkInNotif,
            onChanged: (v) { setState(() => _showArtworkInNotif = v); _save('show_artwork_notif', v); AudioPrefs.showArtworkNotif = v; },
          ),
          _switchTile(context,
            icon: Icons.skip_previous_rounded,
            title: 'Show Previous Track Button',
            subtitle: 'Add previous button in media notification',
            value: _showPrevButton,
            onChanged: (v) { setState(() => _showPrevButton = v); _save('notif_show_prev', v); },
          ),

          // ── NOTIFICATION STYLE ────────────────────────────────────────
          _sectionLabel('NOTIFICATION STYLE'),
          _styleTile(context, 'Compact',  'Small, minimal controls',      Icons.notifications_none_rounded),
          _styleTile(context, 'Expanded', 'Full controls with artwork',   Icons.notifications_active_rounded),
        ],
      ),
    );
  }

  Widget _styleTile(BuildContext context, String style, String sub, IconData icon) {
    final sel = _notifStyle == style;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: sel ? AurumTheme.gold.withOpacity(0.5) : AurumTheme.dividerOf(context),
          width: sel ? 1 : 0.5,
        ),
      ),
      child: ListTile(
        onTap: () { HapticFeedback.selectionClick(); setState(() => _notifStyle = style); _save('notif_style', style); },
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: sel ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgOf(context),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 18),
        ),
        title: Text(style,
          style: TextStyle(
            color: sel ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
            fontSize: 14, fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
        subtitle: Text(sub, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
        trailing: Icon(
          sel ? Icons.check_circle_rounded : Icons.circle_outlined,
          color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 20),
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
