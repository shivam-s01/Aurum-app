import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/aurum_theme.dart';
import '../services/audio_prefs.dart';
import '../l10n/generated/app_localizations.dart';

class SettingsNotificationsScreen extends StatefulWidget {
  const SettingsNotificationsScreen({super.key});
  @override
  State<SettingsNotificationsScreen> createState() => _SettingsNotificationsScreenState();
}

class _SettingsNotificationsScreenState extends State<SettingsNotificationsScreen>
    with WidgetsBindingObserver {
  bool   _showMediaNotif      = true;
  bool   _showArtworkInNotif  = true;
  String _notifStyle          = 'Expanded';

  // New
  bool _showPrevButton = true;

  // THE fix for "background run nahi kar raha" on aggressive OEM skins
  // (Realme/ColorOS, MIUI, etc): these manufacturers kill background
  // services far more readily than stock Android unless the user
  // explicitly whitelists the app from battery optimization. Declaring
  // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS in the manifest only lets the app
  // ASK for this — the user still has to grant it via a system dialog,
  // which this tile triggers. Re-checked in didChangeAppLifecycleState
  // (via _refreshBatteryStatus) so the toggle reflects reality immediately
  // when the user comes back from the system settings screen, not just
  // once at initState.
  bool _batteryOptimizationIgnored = false;

  Future<void> _refreshBatteryStatus() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (mounted) setState(() => _batteryOptimizationIgnored = status.isGranted);
  }

  @override
  void initState() {
    super.initState();
    _load();
    _refreshBatteryStatus();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refreshes the toggle the instant the user comes back from the
    // system battery-optimization settings screen, rather than requiring
    // them to leave and re-enter this screen to see the updated state.
    if (state == AppLifecycleState.resumed) _refreshBatteryStatus();
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
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, l10n.settingsNotifications),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [

          // ── BACKGROUND PLAYBACK ───────────────────────────────────────
          // THE most impactful fix for "background mein gaana ruk jaata
          // hai" on Realme/Xiaomi/other aggressive OEMs — those skins kill
          // background services within minutes unless the user manually
          // exempts the app from battery optimization. This can't be done
          // silently; Android requires an explicit user-facing system
          // dialog for this specific permission.
          _sectionLabel(l10n.snBackgroundPlayback),
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              onTap: _batteryOptimizationIgnored
                  ? null
                  : () async {
                      HapticFeedback.selectionClick();
                      final status = await Permission.ignoreBatteryOptimizations.request();
                      if (mounted) setState(() => _batteryOptimizationIgnored = status.isGranted);
                      // Some OEM skins (Realme/ColorOS, MIUI, etc.) don't
                      // honor the standard Android dialog reliably and
                      // need their own separate "auto-start"/"battery
                      // saver whitelist" screen — send the user to app
                      // settings as a fallback so they can find it
                      // manually if the standard prompt didn't stick.
                      if (mounted && !status.isGranted && status.isPermanentlyDenied) {
                        openAppSettings();
                      }
                    },
              leading: Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: _batteryOptimizationIgnored
                      ? AurumTheme.gold.withOpacity(0.15)
                      : AurumTheme.bgOf(context),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _batteryOptimizationIgnored
                      ? Icons.battery_charging_full_rounded
                      : Icons.battery_alert_rounded,
                  color: _batteryOptimizationIgnored
                      ? AurumTheme.gold
                      : AurumTheme.textMutedOf(context),
                  size: 18,
                ),
              ),
              title: Text(
                _batteryOptimizationIgnored
                    ? l10n.snBgPlaybackEnabled
                    : l10n.snAllowBgPlayback,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 14, fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                _batteryOptimizationIgnored
                    ? l10n.snBgPlaybackEnabledDesc
                    : l10n.snAllowBgPlaybackDesc,
                style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12),
              ),
              trailing: _batteryOptimizationIgnored
                  ? Icon(Icons.check_circle_rounded, color: AurumTheme.gold, size: 20)
                  : Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context), size: 20),
            ),
          ),

          // ── PLAYER NOTIFICATION ───────────────────────────────────────
          _sectionLabel(l10n.snPlayerNotification),
          _switchTile(context,
            icon: Icons.notifications_rounded,
            title: l10n.snShowMediaNotif,
            subtitle: l10n.snShowMediaNotifSubtitle,
            value: _showMediaNotif,
            onChanged: (v) { setState(() => _showMediaNotif = v); _save('show_media_notif', v); AudioPrefs.showMediaNotif = v; },
          ),
          _switchTile(context,
            icon: Icons.image_rounded,
            title: l10n.snShowArtwork,
            subtitle: l10n.snShowArtworkSubtitle,
            value: _showArtworkInNotif,
            onChanged: (v) { setState(() => _showArtworkInNotif = v); _save('show_artwork_notif', v); AudioPrefs.showArtworkNotif = v; },
          ),
          _switchTile(context,
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
        ],
      ),
    );
  }

  Widget _styleTile(BuildContext context, String style, String label, String sub, IconData icon) {
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
        title: Text(label,
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
