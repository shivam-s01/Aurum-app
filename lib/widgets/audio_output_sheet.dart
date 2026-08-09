// =============================================================================
// FILE: lib/widgets/audio_output_sheet.dart
// PROJECT: Aurum Music
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
import '../services/native_engine_bridge.dart';
import '../services/audio_prefs.dart';
import '../utils/aurum_haptics.dart';
import 'aurum_artwork.dart';

/// Opens the audio output picker as a bottom sheet. Call this from any
/// screen with a live PlayerProvider in context (full player, mini
/// player, etc).
Future<void> showAudioOutputSheet(BuildContext context) async {
  AurumHaptics.light();
  final isLight = Theme.of(context).brightness == Brightness.light;
  await showModalBottomSheet(
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
  // Debounces setMediaVolume while dragging: only the last value in a
  // burst is actually sent to the platform channel, so a fast drag
  // doesn't flood it with dozens of calls.
  Timer? _volumeDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _loadVolume();
  }

  @override
  void dispose() {
    _volumeDebounce?.cancel();
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
    });
  }

  void _onVolumeChanged(double value) {
    setState(() => _volume = value.round());
    _volumeDebounce?.cancel();
    _volumeDebounce = Timer(const Duration(milliseconds: 40), () {
      final v = _volume;
      if (v == null) return;
      context.read<PlayerProvider>().engine.setMediaVolume(v);
    });
  }

  /// Live label for the currently playing stream's resolved quality —
  /// e.g. "320 kbps" — falling back to "Auto" when the current source
  /// has no discrete tier reported (matches Settings → Player & Audio's
  /// own "Auto" default label, so the two screens never disagree).
  String get _qualityLabel {
    final kbps = AudioPrefs.lastResolvedKbps;
    if (kbps == null) return 'Auto';
    return '$kbps kbps';
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
                      Builder(builder: (context) {
                        final song =
                            context.watch<PlayerProvider>().currentSong;
                        return AurumArtwork(
                          url: song?.artworkUrl ?? '',
                          size: 44,
                          borderRadius: 10,
                        );
                      }),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Consumer<PlayerProvider>(
                          builder: (context, player, _) {
                            final song = player.currentSong;
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
                                if (song != null) ...[
                                  const SizedBox(height: 2),
                                  Text(song.title,
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
                _VolumeRow(
                  volume: _volume,
                  max: _maxVolume,
                  onChanged: _onVolumeChanged,
                ),
                Divider(
                    color: AurumTheme.textMutedOf(context).withOpacity(0.1),
                    height: 1),
                if (_loading && devices == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                        child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AurumTheme.gold))),
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
                                  ? AurumTheme.gold.withOpacity(0.15)
                                  : AurumTheme.textMutedOf(context)
                                      .withOpacity(0.08),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(_iconFor(d.kind),
                                color: d.selected
                                    ? AurumTheme.gold
                                    : AurumTheme.textMutedOf(context),
                                size: 20),
                          ),
                          title: Text(d.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: d.selected
                                      ? AurumTheme.gold
                                      : AurumTheme.textPrimaryOf(context),
                                  fontSize: 14,
                                  fontWeight: d.selected
                                      ? FontWeight.w700
                                      : FontWeight.w600)),
                          trailing: isPending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AurumTheme.gold))
                              : d.selected
                                  ? const Icon(Icons.check_circle_rounded,
                                      color: AurumTheme.gold, size: 22)
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
                  value: _qualityLabel,
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
class _VolumeRow extends StatelessWidget {
  final int? volume;
  final int max;
  final ValueChanged<double> onChanged;

  const _VolumeRow({
    required this.volume,
    required this.max,
    required this.onChanged,
  });

  IconData get _icon {
    final v = volume;
    if (v == null || v <= 0) return Icons.volume_off_rounded;
    if (v < max * 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final muted = AurumTheme.textMutedOf(context);
    final v = volume;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        children: [
          Icon(_icon, color: muted, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: AurumTheme.gold,
                inactiveTrackColor: muted.withOpacity(0.18),
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                thumbColor: AurumTheme.gold,
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 16),
                overlayColor: AurumTheme.gold.withOpacity(0.18),
              ),
              child: Slider(
                value: (v ?? 0).toDouble().clamp(0, max.toDouble()),
                min: 0,
                max: max.toDouble(),
                // Null (not yet loaded) renders as a disabled-looking
                // slider at 0 rather than a misleading full/empty guess —
                // onChanged is still wired so it becomes interactive the
                // instant the initial getMediaVolume() call resolves.
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact icon + label + value row — used for the "Quality" line.
/// Purely informational (no tap target), matching the reference sheet's
/// "Equalizer / Quality" rows but restyled and reduced to just the one
/// row Aurum actually needs.
class _SheetInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SheetInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final primary = AurumTheme.textPrimaryOf(context);
    final muted = AurumTheme.textMutedOf(context);
    return Padding(
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
                  color: AurumTheme.gold,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
