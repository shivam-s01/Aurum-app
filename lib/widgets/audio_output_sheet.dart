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
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../services/native_engine_bridge.dart';

/// Opens the audio output picker as a bottom sheet. Call this from any
/// screen with a live PlayerProvider in context (full player, mini
/// player, etc).
Future<void> showAudioOutputSheet(BuildContext context) async {
  HapticFeedback.lightImpact();
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

  @override
  void initState() {
    super.initState();
    _load();
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
    HapticFeedback.selectionClick();
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
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AurumTheme.gold.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AurumTheme.gold.withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.speaker_group_rounded,
                            color: AurumTheme.gold, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(l10n.audioOutputPickerTitle,
                            style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
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
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}
