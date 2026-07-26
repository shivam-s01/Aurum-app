// =============================================================================
// FILE: lib/widgets/cast_button.dart
// Chromecast button — matches Spotify's cast icon behavior: hidden if
// unsupported, outline icon when devices are available, pulsing while
// connecting, filled gold + device name once connected.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../services/native_engine_bridge.dart';
import '../services/audio_prefs.dart';

/// Compact cast icon button for the full player's top bar. Renders
/// nothing (zero width) if Cast isn't supported on this device, and
/// nothing if no Cast devices are on the network — same as Spotify only
/// showing the icon when it's actually actionable.
class CastIconButton extends StatelessWidget {
  final Color? color;
  final double size;
  const CastIconButton({super.key, this.color, this.size = 21});

  Future<void> _onTap(BuildContext context, CastState state) async {
    HapticFeedback.lightImpact();
    final engine = context.read<PlayerProvider>().engine;
    if (state.isConnected) {
      _showCastSheet(context);
    } else {
      await engine.showCastPicker();
    }
  }

  void _showCastSheet(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet(
      context: context,
      backgroundColor: isLight ? AurumTheme.lightBgCard : AurumTheme.darkBgElevated,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _CastSessionSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PlayerProvider>().engine;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final c = color ?? (isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(200));

    return ValueListenableBuilder<String>(
      valueListenable: AudioPrefs.castIconVisibilityNotifier,
      builder: (context, visibility, _) {
        if (visibility == 'hidden') return const SizedBox.shrink();

        return StreamBuilder<CastState>(
          stream: engine.castStateStream,
          initialData: engine.castState,
          builder: (context, snapshot) {
            final state = snapshot.data ?? const CastState();
            // 'always': show once the Cast SDK itself is supported on this
            // device, regardless of whether a device is currently detected
            // on the network — matches what the setting promises ("always
            // visible"). Still hidden if the Cast SDK genuinely can't run
            // here (broken/missing Google Play Services), since there's
            // nothing a tap could do in that case.
            // 'auto' (default): only show once a device is actually
            // reachable, same as Spotify/YT Music.
            final shouldShow = visibility == 'always'
                ? state.supported
                : (state.supported && state.status != CastConnectionStatus.unavailable);
            if (!shouldShow) {
              return const SizedBox.shrink();
            }
            final connected = state.isConnected;
            final connecting = state.isConnecting;

            return Semantics(
              label: connected
                  ? AppLocalizations.of(context)!
                      .castingToDevice(state.deviceName ?? AppLocalizations.of(context)!.castDeviceFallbackName)
                  : AppLocalizations.of(context)!.castToDeviceLabel,
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _onTap(context, state),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: connecting
                      ? SizedBox(
                          width: size,
                          height: size,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AurumTheme.gold,
                          ),
                        )
                      : Icon(
                          connected ? Icons.cast_connected_rounded : Icons.cast_rounded,
                          size: size,
                          color: connected ? AurumTheme.gold : c,
                        ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Small "Casting to X" banner — drop this under the top bar or above
/// the artwork in the full player when a session is active, matching
/// Spotify's persistent cast strip.
class CastingBanner extends StatelessWidget {
  const CastingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PlayerProvider>().engine;
    return StreamBuilder<CastState>(
      stream: engine.castStateStream,
      initialData: engine.castState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const CastState();
        if (!state.isConnected) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AurumTheme.gold.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AurumTheme.gold.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cast_connected_rounded, size: 14, color: AurumTheme.gold),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    AppLocalizations.of(context)!.castingToDevice(
                        state.deviceName ??
                            AppLocalizations.of(context)!.castDeviceFallbackName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AurumTheme.gold,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Bottom sheet shown when tapping the cast icon while already connected
/// — lets the user disconnect or stop casting entirely, same two options
/// Spotify's cast sheet offers.
class _CastSessionSheet extends StatelessWidget {
  const _CastSessionSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final engine = context.read<PlayerProvider>().engine;
    final state = engine.castState;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AurumTheme.textMutedOf(context).withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Row(children: [
              const Icon(Icons.cast_connected_rounded, color: AurumTheme.gold, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  state.deviceName ?? l10n.castDeviceFallbackTitle,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.cast_rounded),
              title: Text(l10n.castSessionDisconnect),
              onTap: () {
                engine.endCastSession(stopCasting: false);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.stop_circle_outlined),
              title: Text(l10n.castSessionStopCasting),
              onTap: () {
                engine.endCastSession(stopCasting: true);
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
