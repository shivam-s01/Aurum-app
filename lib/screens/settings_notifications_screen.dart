import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../services/audio_prefs.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_settings_tile.dart';
import '../utils/aurum_motion.dart';

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

  // FIX (toggle flash — see settings_appearance_screen.dart for the full
  // root-cause writeup): _showMediaNotif/_showArtworkInNotif/etc default to
  // hardcoded values before _load()'s async SharedPreferences read
  // resolves, so the first build() paints those defaults for a frame, then
  // snaps to the real saved value once _load() completes. Gate the real UI
  // behind a brief loader until the real values are ready.
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showMediaNotif     = p.getBool('show_media_notif')    ?? true;
      _showArtworkInNotif = p.getBool('show_artwork_notif')  ?? true;
      _notifStyle         = p.getString('notif_style')       ?? 'Expanded';
      _showPrevButton     = p.getBool('notif_show_prev')     ?? true;
      _loaded = true;
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool)   await p.setBool(key, value);
    if (value is String) await p.setString(key, value);
    // Reload live so AudioPrefs-dependent behavior (e.g. stream quality
    // checks elsewhere) picks up the new value immediately.
    //
    // NOTE: unlike the old audio_service-based AurumAudioHandler, there is
    // no "reloadSettings" native call needed here anymore — Media3's
    // MediaSessionService-driven notification (AurumMediaSessionService.kt)
    // is generated automatically from the MediaSession/MediaMetadata on
    // every player state change, not from a manually-populated
    // notification config that needed an explicit refresh signal. The
    // show/artwork/prev-button toggles below currently only affect what
    // this settings screen persists to SharedPreferences; wiring them into
    // the actual notification layout (e.g. hiding the prev button) would
    // require reading these prefs from AurumMediaSessionService's
    // CommandButton/custom-layout setup — not yet implemented there.
    await AudioPrefs.load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (!_loaded) {
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        appBar: _appBar(context, l10n.settingsNotifications),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final rows = <Widget>[
      // ── PLAYER NOTIFICATION ───────────────────────────────────────
      _sectionLabel(l10n.snPlayerNotification),
      AurumSettingsTile.switchTile(context,
        icon: Icons.notifications_rounded,
        title: l10n.snShowMediaNotif,
        subtitle: l10n.snShowMediaNotifSubtitle,
        value: _showMediaNotif,
        onChanged: (v) { setState(() => _showMediaNotif = v); _save('show_media_notif', v); AudioPrefs.showMediaNotif = v; },
      ),
      AurumSettingsTile.switchTile(context,
        icon: Icons.image_rounded,
        title: l10n.snShowArtwork,
        subtitle: l10n.snShowArtworkSubtitle,
        value: _showArtworkInNotif,
        onChanged: (v) { setState(() => _showArtworkInNotif = v); _save('show_artwork_notif', v); AudioPrefs.showArtworkNotif = v; },
      ),
      AurumSettingsTile.switchTile(context,
        icon: Icons.skip_previous_rounded,
        title: l10n.snShowPrevButton,
        subtitle: l10n.snShowPrevButtonSubtitle,
        value: _showPrevButton,
        onChanged: (v) { setState(() => _showPrevButton = v); _save('notif_show_prev', v); },
      ),

      // ── NOTIFICATION STYLE ────────────────────────────────────────
      _sectionLabel(l10n.snNotificationStyle),
      _styleTile(context, 'Compact', l10n.snStyleCompact, l10n.snStyleCompactDesc, Icons.notifications_none_rounded),
      _styleTile(context, 'Expanded', l10n.snStyleExpanded, l10n.snStyleExpandedDesc, Icons.notifications_active_rounded),
    ];

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, l10n.settingsNotifications),
      body: ListView(
        // AlwaysScrollableScrollPhysics wraps BouncingScrollPhysics so the
        // bounce still fires even when this screen's content is shorter
        // than the viewport (e.g. after Background Playback was removed,
        // Notifications dropped to a handful of rows) — plain
        // BouncingScrollPhysics only bounces once content actually
        // overflows and needs to scroll; on a short, non-scrolling list it
        // silently does nothing, which is why this screen alone felt
        // "stuck" compared to longer screens like About/Privacy where the
        // content naturally overflows and the same physics line works
        // without this wrapper.
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          for (int i = 0; i < rows.length; i++)
            AurumStaggerItem(index: i, child: rows[i]),
        ],
      ),
    );
  }

  Widget _styleTile(BuildContext context, String style, String label, String sub, IconData icon) {
    final sel = _notifStyle == style;
    return AurumPressable(
      onTap: () { setState(() => _notifStyle = style); _save('notif_style', style); },
      scaleAmount: 0.98,
      child: AnimatedContainer(
        duration: AurumMotion.durationOrZero(AurumMotion.short2),
        curve: AurumMotion.standard,
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading: AnimatedContainer(
            duration: AurumMotion.durationOrZero(AurumMotion.short2),
            curve: AurumMotion.standard,
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: sel ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgOf(context),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 18),
          ),
          title: Text(label,
            style: TextStyle(
              color: sel ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
              fontSize: 14, fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
          subtitle: Text(sub, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
          trailing: AnimatedSwitcher(
            duration: AurumMotion.durationOrZero(AurumMotion.short2),
            child: Icon(
              sel ? Icons.check_circle_rounded : Icons.circle_outlined,
              key: ValueKey(sel),
              color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 20),
          ),
        ),
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


