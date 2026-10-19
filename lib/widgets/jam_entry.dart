// ═══════════════════════════════════════════════════════════════════════════
// FILE: lib/widgets/jam_entry.dart
// DESCRIPTION: Entry points to Astra Jam from the full players.
//   • JamConnectIcon      — Spotify-Connect-style speaker glyph (vector, no image)
//   • openJamPage         — opens the Jam page as a normal full page
//   • showSleepOrJamSheet — the 2-choice sheet: Sleep timer / Jam
//
// Lightweight: one tiny CustomPainter, no blur, no animation, no images.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';

import '../providers/player_provider.dart';
import '../screens/full_player_screen.dart' show showSleepTimerForSong;
import '../screens/jam_screen.dart';
import '../screens/settings_player_screen.dart' show SleepTimerService;
import '../services/jam_service.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_transitions.dart' show AurumPageRoute;
import 'aurum_pressable.dart';

/// Opens the Jam page like any other page (slide-in, back arrow to return).
void openJamPage(BuildContext context) {
  AurumHaptics.light();
  Navigator.of(context).push(AurumPageRoute(builder: (_) => const JamScreen()));
}

/// Jam glyph: two overlapping rings (listening together) with a small dot in
/// the overlap. Original vector drawing — crisp at any size, costs nothing.
class JamConnectIcon extends StatelessWidget {
  final double size;
  final Color color;
  const JamConnectIcon({super.key, this.size = 22, this.color = Colors.white70});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _JamPainter(color),
      );
}

class _JamPainter extends CustomPainter {
  final Color color;
  const _JamPainter(this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final u = s.width / 24.0;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * u
      ..isAntiAlias = true;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawCircle(Offset(8.6 * u, 12 * u), 6.2 * u, stroke);
    canvas.drawCircle(Offset(15.4 * u, 12 * u), 6.2 * u, stroke);
    canvas.drawCircle(Offset(12 * u, 12 * u), 1.5 * u, fill);
  }

  @override
  bool shouldRepaint(_JamPainter old) => old.color != color;
}

/// Sleep icon tap → two simple choices. The user picks what they want.
Future<void> showSleepOrJamSheet(BuildContext context, PlayerProvider player) {
  final hi = Localizations.localeOf(context).languageCode == 'hi';
  String t(String en, String h) => hi ? h : en;
  return showAurumModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) {
      final bg = AurumTheme.bgCardOf(sheetCtx);
      final tp = AurumTheme.textPrimaryOf(sheetCtx);
      final ts = AurumTheme.textSecondaryOf(sheetCtx);
      return SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: ts.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListenableBuilder(
                listenable: SleepTimerService.instance,
                builder: (_, __) {
                  final on = SleepTimerService.instance.isActive;
                  return _OptionRow(
                    icon: Icon(
                      on ? Icons.bedtime_rounded : Icons.dark_mode_outlined,
                      color: tp,
                      size: 24,
                    ),
                    title: t('Sleep timer', 'Sleep timer'),
                    subtitle: on
                        ? t('On • tap to change', 'Chalu • badalne ke liye tap karo')
                        : t('Stop the music after some time', 'Kuch der baad gaana band ho jayega'),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      showSleepTimerForSong(context, player);
                    },
                  );
                },
              ),
              ListenableBuilder(
                listenable: JamService.instance,
                builder: (_, __) {
                  final on = JamService.instance.inRoom;
                  return _OptionRow(
                    icon: JamConnectIcon(
                      size: 24,
                      color: on ? const Color(0xFF1ED760) : tp,
                    ),
                    title: 'Jam',
                    subtitle: on
                        ? t('You are in a Jam', 'Aap Jam me ho')
                        : t('Listen together with friends', 'Doston ke saath ek hi gaana suno'),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      openJamPage(context);
                    },
                  );
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _OptionRow extends StatelessWidget {
  final Widget icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _OptionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    return AurumPressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tp.withOpacity(0.08),
            ),
            alignment: Alignment.center,
            child: icon,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(color: tp, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(color: ts, fontSize: 13)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: ts, size: 22),
        ]),
      ),
    );
  }
}
