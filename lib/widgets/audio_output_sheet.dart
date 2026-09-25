// =============================================================================
// FILE: lib/widgets/audio_output_sheet.dart
// PROJECT: Astra Music
// DESCRIPTION: In-app audio output device picker — speaker / wired
//   headphones / Bluetooth / USB. One of the 3 "confirmed missing"
//   features from the app review (Chromecast + playlist multi-select
//   bulk actions are the other two).
//
//   Backed by AurumAudioOutputManager.kt via NativeAudioEngine
//   (getAudioOutputDevices / selectAudioOutputDevice / setForceSpeaker),
//   with a live EventChannel stream so Bluetooth connect/disconnect
//   updates the sheet without the user reopening it.
//
//   Also hosts the system media-volume slider and a live "Quality" row
//   (actual resolved kbps of the current stream, not a static label) —
//   the two other rows a premium output sheet needs alongside device
//   selection. Volume reads/writes go through getMediaVolume/
//   setMediaVolume, which only ever touch Android's AudioManager
//   STREAM_MUSIC — completely isolated from AurumAudioEngine's internal
//   fade/duck/crossfade volume, so there's no path for this to ever
//   fight that code for control.
// =============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../models/song.dart';
import '../services/native_engine_bridge.dart';
import '../services/audio_prefs.dart';
import '../services/stream_quality_store.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../screens/settings_player_screen.dart' show SettingsPlayerScreen;
import '../utils/aurum_transitions.dart';
import 'aurum_artwork.dart';

/// Opens the audio output picker as a bottom sheet. Call this from any
/// screen with a live PlayerProvider in context (full player, mini
/// player, etc).
Future<void> showAudioOutputSheet(BuildContext context) async {
  AurumHaptics.light();
  final isLight = Theme.of(context).brightness == Brightness.light;
  await showAurumModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor:
        isLight ? AurumTheme.lightBgCard : AurumTheme.darkBgElevated,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => const _AudioOutputSheet(),
  );
}

class _AudioOutputSheet extends StatefulWidget {
  const _AudioOutputSheet();

  @override
  State<_AudioOutputSheet> createState() => _AudioOutputSheetState();
}

class _AudioOutputSheetState extends State<_AudioOutputSheet> {
  AudioOutputDevices? _devices;
  bool _loading = true;
  // Tracks an in-flight tap so rapid double-taps on two different rows
  // can't both be "selecting" at once and race each other's optimistic
  // UI update.
  int? _pendingDeviceId;

  // Local optimistic volume state. The slider always renders from this,
  // never straight from a re-fetch — dragging feels instant and never
  // jitters back from a slightly-stale native read.
  int? _volume;
  int _maxVolume = 15;
  // Volume Boost slice (100-200) — the slider's 100%-200% range, past
  // hardware max. Kept separate from _volume/_maxVolume (which stay pure
  // STREAM_MUSIC as before) and combined into one continuous 0.0-2.0
  // fraction only at render/drag time — see _sliderFraction /
  // _onSliderChanged. Starts at 100 (off) until _loadVolume() resolves.
  int _boostPercent = 100;
  // True only while the user's thumb is actively down on the slider —
  // see the StreamBuilder around _VolumeRow in build() for why this
  // exists: it's what stops a live external volume change (hardware
  // keys, another app) from fighting an in-progress drag gesture.
  bool _isDragging = false;
  // Debounces setMediaVolume while dragging: only the last value in a
  // burst is actually sent to the platform channel, so a fast drag
  // doesn't flood it with dozens of calls.
  Timer? _volumeDebounce;
  // Same debounce idea for setVolumeBoost — native already ramps the
  // actual gain smoothly on its side (see AurumAudioEffects.setVolumeBoost),
  // this just avoids flooding the channel with every pixel of drag.
  Timer? _boostDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _loadVolume();
  }

  @override
  void dispose() {
    _volumeDebounce?.cancel();
    _boostDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final engine = context.read<PlayerProvider>().engine;
    final devices = await engine.getAudioOutputDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  Future<void> _loadVolume() async {
    final engine = context.read<PlayerProvider>().engine;
    final mv = await engine.getMediaVolume();
    if (!mounted) return;
    setState(() {
      _volume = mv.level;
      _maxVolume = mv.max > 0 ? mv.max : 1;
      _boostPercent = mv.boostPercent;
    });
  }

  void _onSliderChanged(double fraction) {
    final clamped = fraction.clamp(0.0, 2.0);
    if (clamped <= 1.0) {
      final newVolume = (clamped * _maxVolume).round();
      setState(() {
        _volume = newVolume;
        // Snapping hardware back down below max always fully disengages
        // boost too — dragging left off the 200% end should feel like one
        // continuous motion back toward silence, not leave boost stuck on
        // at some stale percent while hardware volume drops.
        if (_boostPercent != 100) _boostPercent = 100;
      });
      _volumeDebounce?.cancel();
      _volumeDebounce = Timer(const Duration(milliseconds: 40), () {
        final v = _volume;
        if (v == null) return;
        final engine = context.read<PlayerProvider>().engine;
        engine.setMediaVolume(v);
        // Ensure boost is actually re-sent to native once when crossing
        // back under 100%, not just optimistically zeroed locally.
        engine.setVolumeBoost(100);
      });
    } else {
      final newBoost = (100 + (clamped - 1.0) * 100).round();
      setState(() {
        // Hardware volume is pinned at max while in boost territory —
        // matches how the underlying gain path works (boost only ever
        // adds on top of a maxed-out hardware stream).
        _volume = _maxVolume;
        _boostPercent = newBoost;
      });
      _volumeDebounce?.cancel();
      _volumeDebounce = Timer(const Duration(milliseconds: 40), () {
        final v = _volume;
        if (v == null) return;
        context.read<PlayerProvider>().engine.setMediaVolume(v);
      });
      _boostDebounce?.cancel();
      _boostDebounce = Timer(const Duration(milliseconds: 40), () {
        context.read<PlayerProvider>().engine.setVolumeBoost(_boostPercent);
      });
    }
  }

  /// Quality row = exactly what the user picked in Settings > Player &
  /// Audio, shown as the same kbps text Settings prints under that tier
  /// (High = 320 kbps, Medium = up to 160 kbps, Low = 48-96 kbps).
  ///
  /// FIX ("setting mein user ne jo select kiya wahi kbps show ho"): the
  /// sheet used to show a raw resolved kbps / bare "Auto". Now it follows
  /// the Settings choice so the two screens can never disagree.
  ///   - High       -> "320 kbps"
  ///   - Medium     -> "Up to 160 kbps"
  ///   - Low        -> "48-96 kbps"
  ///   - Smart Saver / Auto -> no fixed kbps exists (Smart Saver adapts to
  ///     the network, Auto = best per song), so the tier name is shown,
  ///     plus the real resolved kbps when the current stream reported one.
  ///   - local file -> "Local · MP3" (Settings tier doesn't apply)
  String _qualityLabel(AppLocalizations l10n) {
    final song = context.read<PlayerProvider>().currentSong;
    if (song != null && song.isLocal) {
      final codec = StreamQualityStore.instance.codecFor(song);
      return codec != null ? 'Local · $codec' : 'Local file';
    }
    final resolved = (song != null && song.source == SongSource.youtube)
        ? null
        : AudioPrefs.lastResolvedKbps;
    switch (AudioPrefs.streamQuality) {
      case 'High':
        return '320 kbps';
      case 'Medium':
        return 'Up to 160 kbps';
      case 'Low':
        return '48-96 kbps';
      case 'DataSaver':
        return resolved != null
            ? '${l10n.spQualityDataSaver} · $resolved kbps'
            : l10n.spQualityDataSaver;
      default:
        return resolved != null
            ? '${l10n.spQualityAuto} · $resolved kbps'
            : l10n.spQualityAuto;
    }
  }

  Future<void> _onSelect(AudioOutputDevice device) async {
    if (_pendingDeviceId != null) return; // ignore taps mid-selection
    final engine = context.read<PlayerProvider>().engine;
    final supportsRouting = _devices?.supportsExplicitRouting ?? false;
    final l10n = AppLocalizations.of(context)!;

    if (!supportsRouting) {
      // Pre-Android-12: no explicit per-device routing exists. Being
      // honest about this here (rather than pretending the tap worked)
      // matters more for a "premium, zero-compromise" feel than silently
      // no-op'ing — the user deserves to know why nothing visibly
      // changed.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.audioOutputAutoRoutingNotice),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
      return;
    }

    setState(() => _pendingDeviceId = device.id);
    AurumHaptics.selection();
    final ok = await engine.selectAudioOutputDevice(device.id);
    if (!mounted) return;
    setState(() => _pendingDeviceId = null);

    if (ok) {
      // Optimistically mark this device selected in the local snapshot —
      // the live EventChannel stream will also confirm shortly, but
      // updating immediately avoids a visible lag between tap and
      // checkmark on devices where the stream takes a beat to fire.
      setState(() {
        final current = _devices;
        if (current != null) {
          _devices = AudioOutputDevices(
            supportsExplicitRouting: current.supportsExplicitRouting,
            devices: current.devices
                .map((d) => AudioOutputDevice(
                      id: d.id,
                      name: d.name,
                      kind: d.kind,
                      selected: d.id == device.id,
                    ))
                .toList(),
          );
        }
      });
      if (mounted) Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.audioOutputSwitchFailed),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  IconData _iconFor(AudioOutputDeviceKind kind) {
    switch (kind) {
      case AudioOutputDeviceKind.speaker:
        return Icons.smartphone_rounded;
      case AudioOutputDeviceKind.wired:
        return Icons.headphones_rounded;
      case AudioOutputDeviceKind.bluetooth:
        return Icons.bluetooth_audio_rounded;
      case AudioOutputDeviceKind.usb:
        return Icons.usb_rounded;
      case AudioOutputDeviceKind.unknown:
        return Icons.speaker_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final engine = context.read<PlayerProvider>().engine;
    // Rebuild only when the track changes, so the Quality row below never
    // stays stale if the user skips a song while this sheet is open.
    context.select<PlayerProvider, String>((p) => p.currentSong?.id ?? '');

    return StreamBuilder<AudioOutputDevices?>(
      stream: engine.outputDevicesStream,
      builder: (context, snapshot) {
        // Live stream update (device connected/disconnected) takes
        // priority over the initial one-shot load once it arrives.
        final devices = snapshot.data ?? _devices;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  decoration: BoxDecoration(
                    color: AurumTheme.textMutedOf(context).withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      Selector<PlayerProvider, String>(
                        selector: (_, p) => p.currentSong?.artworkUrl ?? '',
                        builder: (context, artworkUrl, _) {
                          return AurumArtwork(
                            url: artworkUrl,
                            size: 44,
                            borderRadius: 10,
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        // PERF (consistency with mini_player.dart/queue_screen.dart's
                        // same fix): Consumer<PlayerProvider> here rebuilt on every
                        // playback-position notifyListeners() tick — multiple times a
                        // second — for a title/subtitle Text that only actually needs
                        // to change when the current song itself changes. A Selector
                        // scoped to just currentSong?.id/title stops that redundant
                        // rebuild without changing anything else about this widget.
                        child: Selector<PlayerProvider, (String?, String)>(
                          selector: (_, p) => (p.currentSong?.id, p.currentSong?.title ?? ''),
                          builder: (context, data, _) {
                            final (songId, title) = data;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(l10n.audioOutputPickerTitle,
                                    style: TextStyle(
                                        color: AurumTheme.textMutedOf(
                                            context),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600)),
                                if (songId != null) ...[
                                  const SizedBox(height: 2),
                                  Text(title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: AurumTheme.textPrimaryOf(
                                              context),
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700)),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                    color: AurumTheme.textMutedOf(context).withOpacity(0.1),
                    height: 1),
                // FEATURE ("volume badane ka option live update nahi hota,
                // phone button se badhau to bhi wahi rehta hai" —
                // 2026-09-07): mediaVolumeStream now pushes a fresh value
                // any time STREAM_MUSIC changes from ANY source (hardware
                // keys, another app, this app's own slider) — see
                // native_engine_bridge.dart's mediaVolumeStream doc for
                // the native side. _isDragging guards against the live
                // stream fighting the user's own in-progress drag: while
                // actively dragging, the local optimistic _volume (set
                // synchronously in _onVolumeChanged) stays authoritative,
                // exactly like _volume already did before this stream
                // existed — the live value only takes over once the user
                // isn't the one currently moving the thumb.
                StreamBuilder<MediaVolume?>(
                  stream: engine.mediaVolumeStream,
                  builder: (context, volSnapshot) {
                    final live = volSnapshot.data;
                    // Live hardware-volume events (hardware keys, another
                    // app) never carry a live boostPercent — see
                    // native_engine_bridge.dart's mediaVolumeStream doc —
                    // so only _volume/_maxVolume follow the live stream
                    // here; _boostPercent always comes from local state,
                    // which only this sheet ever changes.
                    final effectiveVolume =
                        (!_isDragging && live != null) ? live.level : _volume;
                    final effectiveMax =
                        (!_isDragging && live != null && live.max > 0)
                            ? live.max
                            : _maxVolume;
                    final fraction = (() {
                      final hw = (effectiveVolume ?? 0) /
                          (effectiveMax <= 0 ? 1 : effectiveMax);
                      final boost = (_boostPercent - 100) / 100.0;
                      return (hw + boost).clamp(0.0, 2.0);
                    })();
                    return _VolumeRow(
                      fraction: fraction,
                      boosted: _boostPercent > 100,
                      onChanged: _onSliderChanged,
                      onDragStart: () => setState(() => _isDragging = true),
                      onDragEnd: () => setState(() => _isDragging = false),
                    );
                  },
                ),
                Divider(
                    color: AurumTheme.textMutedOf(context).withOpacity(0.1),
                    height: 1),
                if (_loading && devices == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                        child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AurumTheme.accentOf(context)))),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.of(context).size.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: devices?.devices.length ?? 0,
                      itemBuilder: (_, i) {
                        final d = devices!.devices[i];
                        final isPending = _pendingDeviceId == d.id;
                        return ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: d.selected
                                  ? AurumTheme.accentOf(context).withOpacity(0.15)
                                  : AurumTheme.textMutedOf(context)
                                      .withOpacity(0.08),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(_iconFor(d.kind),
                                color: d.selected
                                    ? AurumTheme.accentOf(context)
                                    : AurumTheme.textMutedOf(context),
                                size: 20),
                          ),
                          title: Text(d.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: d.selected
                                      ? AurumTheme.accentOf(context)
                                      : AurumTheme.textPrimaryOf(context),
                                  fontSize: 14,
                                  fontWeight: d.selected
                                      ? FontWeight.w700
                                      : FontWeight.w600)),
                          trailing: isPending
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AurumTheme.accentOf(context)))
                              : d.selected
                                  ? Icon(Icons.check_circle_rounded,
                                      color: AurumTheme.accentOf(context), size: 22)
                                  : null,
                          onTap: () => _onSelect(d),
                        );
                      },
                    ),
                  ),
                if (!_loading &&
                    devices != null &&
                    !devices.supportsExplicitRouting)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Text(
                      l10n.audioOutputAutoRoutingNotice,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AurumTheme.textMutedOf(context),
                          fontSize: 11.5,
                          height: 1.4),
                    ),
                  ),
                Divider(
                    color: AurumTheme.textMutedOf(context).withOpacity(0.1),
                    height: 1),
                _SheetInfoRow(
                  icon: Icons.high_quality_rounded,
                  label: 'Quality',
                  value: _qualityLabel(l10n),
                  // FIX ("Bluetooth sheet ki Quality row tappable honi
                  // chahiye, seedha Settings > Player mein le jaaye"):
                  // this row used to be purely informational (see the
                  // class doc comment above, now stale). Close this
                  // sheet first (Navigator.pop, same as the device-
                  // select flow just above), then push
                  // SettingsPlayerScreen with the app's own premium
                  // AurumDepthRoute transition — same route class every
                  // other settings navigation in the app already uses,
                  // so this doesn't introduce a different-feeling push.
                  onTap: () {
                    AurumHaptics.selection();
                    // FIX (potential crash risk caught on final recheck):
                    // calling Navigator.push(context, ...) right after
                    // Navigator.pop(context) on the SAME context is a
                    // known Flutter footgun — this context belongs to the
                    // sheet's own element, which pop() immediately starts
                    // deactivating, so a push on it a statement later can
                    // throw "Looking up a deactivated widget's ancestor is
                    // unsafe" or target the wrong navigator depending on
                    // timing. Capturing the root Navigator's own state
                    // BEFORE popping, then calling push on that captured
                    // reference, sidesteps the issue entirely — this
                    // reference stays valid regardless of what happens to
                    // the sheet's own context afterward.
                    final rootNavigator =
                        Navigator.of(context, rootNavigator: true);
                    Navigator.pop(context);
                    rootNavigator.push(
                      AurumDepthRoute(
                        builder: (_) =>
                            const SettingsPlayerScreen(highlightQuality: true),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// System media-volume slider, styled to match the rest of the sheet —
/// a slim gold-gradient track with a small glowing thumb, mute icon that
/// updates with the current level (matches the reference "Play on" sheet
/// pattern, just restyled to Aurum's gold-on-dark identity instead of a
/// generic teal Material slider).
///
/// Range is 0.0-2.0: 0.0-1.0 is normal hardware volume (0%-100%, exactly
/// as before), 1.0-2.0 is Volume Boost (100%-200%, extra electrical gain
/// on top — see AurumAudioEffects.setVolumeBoost on the native side for
/// why this is safe to push that far: gain is shared-budget-clamped and
/// always ramped, never snapped, so there's no click/crackle crossing
/// into or moving around the boost zone). A thin marker at the 1.0/100%
/// mark plus an accent-color track change past it makes the boost zone
/// visually distinct, so a user dragging into it knows they've crossed
/// into "louder than normal" territory rather than being surprised by it.
class _VolumeRow extends StatelessWidget {
  final double fraction; // 0.0 - 2.0
  final bool boosted;
  final ValueChanged<double> onChanged;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  const _VolumeRow({
    required this.fraction,
    required this.boosted,
    required this.onChanged,
    this.onDragStart,
    this.onDragEnd,
  });

  IconData get _icon {
    if (fraction <= 0) return Icons.volume_off_rounded;
    if (boosted) return Icons.volume_up_rounded;
    if (fraction < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final muted = AurumTheme.textMutedOf(context);
    final accent = AurumTheme.accentOf(context);
    // Boost zone reads as a warmer/brighter accent than the normal 0-100%
    // track, purely as a visual "you're past 100% now" cue — no separate
    // widget, so the whole thing still feels like one continuous slider.
    final boostColor = Color.lerp(accent, const Color(0xFFFFC94A), 0.5)!;
    final trackColor = boosted ? boostColor : accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        children: [
          Icon(_icon, color: boosted ? boostColor : muted, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 100% mark — a faint tick exactly at the slider's
                // midpoint, behind the track, so the boost boundary is
                // visible without needing a label.
                Align(
                  alignment: Alignment.center,
                  child: Container(
                    width: 2,
                    height: 10,
                    decoration: BoxDecoration(
                      color: muted.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: trackColor,
                    inactiveTrackColor: muted.withOpacity(0.18),
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                    thumbColor: trackColor,
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 16),
                    overlayColor: trackColor.withOpacity(0.18),
                  ),
                  child: Slider(
                    value: fraction.clamp(0.0, 2.0),
                    min: 0.0,
                    max: 2.0,
                    onChanged: onChanged,
                    // Marks the drag window so the live mediaVolumeStream
                    // (see the StreamBuilder wrapping this widget) knows to
                    // stay hands-off of the slider's displayed value until
                    // the user actually lets go — otherwise a live update
                    // arriving mid-drag (e.g. this same setMediaVolume call
                    // echoing back) could yank the thumb out from under the
                    // user's finger.
                    onChangeStart: onDragStart == null
                        ? null
                        : (_) => onDragStart!(),
                    onChangeEnd:
                        onDragEnd == null ? null : (_) => onDragEnd!(),
                  ),
                ),
              ],
            ),
          ),
          if (boosted) ...[
            const SizedBox(width: 8),
            Text(
              '${(100 + (fraction - 1.0).clamp(0.0, 1.0) * 100).round()}%',
              style: TextStyle(
                color: boostColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact icon + label + value row — used for the "Quality" line.
/// Optionally tappable (see onTap) — the Quality row uses this to jump
/// straight into Settings > Player & Audio for the underlying setting.
class _SheetInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _SheetInfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = AurumTheme.textPrimaryOf(context);
    final muted = AurumTheme.textMutedOf(context);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Icon(icon, color: muted, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: primary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          Text(value,
              style: TextStyle(
                  color: AurumTheme.accentOf(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: muted, size: 18),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: row,
    );
  }
}
