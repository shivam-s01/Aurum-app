import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../services/audio_prefs.dart';
import '../screens/main_shell.dart' show AurumBottomNavBar;
import 'mini_player.dart';

// ═══════════════════════════════════════════════════════════════════════
// MINI PLAYER SLOT — Echo Nightly-parity "nav bar hidden on pushed
// screens, mini player still floats above them" behavior.
//
// PATTERN (matches Echo Nightly's isMainFragment / animateTranslation
// exactly): the bottom nav bar is chrome that belongs ONLY to the 3 root
// tabs (Home/Search/Library, MainShell's own IndexedStack). The instant
// any content screen is pushed on top via Navigator.push (Liked Songs,
// Downloads, History, Album, Artist, Mix, Playlists, Playlist Detail —
// Echo's isMainFragment flips to false for the exact same set: any
// fragment that isn't the tab host itself), the nav bar goes away. The
// mini player is independent of that — it still floats here as long as
// something's playing, same as Echo's playerBar staying visible whenever
// isPlayerCollapsed is true regardless of isMainFragment. Only the actual
// full-screen Now Playing view (FullPlayerScreen) hides both entirely,
// same as Echo's STATE_EXPANDED case.
//
// WHY THE RESERVED SPACE BELOW MATTERS: Echo Nightly's nav bar and player
// bar are siblings in ONE persistent view tree — when the nav bar
// translates itself away, the player bar's own bottom margin is computed
// independently (setPlayerNavViewInsets), so it never visibly shifts.
// Aurum's pushed screens are a separate Scaffold from MainShell entirely
// (no shared parent to animate), so simply omitting the nav bar here
// would leave the mini player sitting `barHeight` lower than it does on
// Home/Search/Library — a visible snap/jump right when a screen is
// pushed or popped, reading as janky rather than intentional. Reserving
// an invisible spacer of the exact same height (+ the same docked/
// floating bottom padding AurumBottomNavBar itself uses) keeps the mini
// player pinned at an identical vertical position in both places, so
// only the nav bar's absence changes, not the mini player's position —
// exactly the "balanced" feel Echo achieves via shared-parent animation,
// reached here by shared sizing instead.
//
// USAGE: wrap whatever a pushed content screen would otherwise pass as
// `bottomNavigationBar:` — if that screen has none, just set
// `bottomNavigationBar: const MiniPlayerSlot()` directly on its Scaffold.
// Nothing else about the screen needs to change; this is a drop-in slot,
// not a screen rewrite.
//
// Deliberately mirrors MainShell's exact bottomNavigationBar Material/
// RepaintBoundary wrapping instead of embedding the raw widget directly
// — an earlier version of MainShell hit a "ghost pill" bug where
// Scaffold's bottomNavigationBar slot is always implicitly wrapped in an
// opaque Material by Flutter itself; skipping the same transparent-
// Material fix here would reintroduce that exact bug on every pushed
// screen instead of just MainShell. See main_shell.dart's matching
// comment for the full history.
// ═══════════════════════════════════════════════════════════════════════
class MiniPlayerSlot extends StatelessWidget {
  const MiniPlayerSlot({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      child: RepaintBoundary(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // FIX (white flash on auto-skip reappear — see the matching,
            // more detailed comment in main_shell.dart's bottomNavigationBar
            // for the full mechanism): wrapped in AnimatedSize +
            // AnimatedSwitcher instead of an instant SizedBox.shrink() ↔
            // MiniPlayer() swap, so the layout height change is smoothed
            // over real time rather than jumping in a single frame — that
            // single-frame jump was what let this Scaffold's implicit
            // Material fill flash visible for a beat.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: Selector<PlayerProvider, bool>(
                selector: (_, p) => p.miniPlayerVisible,
                builder: (context, visible, __) => AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: visible
                      ? const MiniPlayer(key: ValueKey('mini_player_visible'))
                      : const SizedBox.shrink(key: ValueKey('mini_player_hidden')),
                ),
              ),
            ),
            // Invisible reserved space — NOT a rendered nav bar (no icons,
            // no tap targets, no background), just the same footprint one
            // would have occupied. See the "WHY THE RESERVED SPACE BELOW
            // MATTERS" doc comment above for the full reasoning.
            ValueListenableBuilder<String>(
              valueListenable: AudioPrefs.navBarStyleNotifier,
              builder: (context, navStyle, _) {
                final docked = navStyle == 'Docked';
                return SafeArea(
                  top: false,
                  child: SizedBox(
                    height: AurumBottomNavBar.barHeight +
                        (docked ? 0 : 10),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
