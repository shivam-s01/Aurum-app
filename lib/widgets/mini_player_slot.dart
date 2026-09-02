import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import 'mini_player.dart';
import '../utils/aurum_motion.dart';

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
// FIX ("ghost pill" on Mix/Playlist/Liked/Downloads — the nav bar itself
// was correctly gone here, but this slot used to reserve an invisible
// SizedBox the exact height of AurumBottomNavBar underneath the mini
// player, "so the mini player doesn't visibly jump vertically when a
// screen is pushed/popped." In practice that spacer wasn't fully
// invisible: it sat inside the same Scaffold-implicit Material fill
// described below, so on any theme/blur combination where that fill
// wasn't pure transparent it painted as a flat, nav-bar-shaped strip
// with nothing in it — exactly the "ekdam pill" artifact, since it's
// literally the nav bar's footprint with all its content stripped out.
// Echo Nightly does NOT reserve this space; its mini player simply sits
// lower on pushed fragments than on the tab host, with no phantom
// footprint held open beneath it. Deleting the spacer here matches that
// exactly — the mini player now just floats with its own safe-area
// bottom inset, nothing reserved beneath it.
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
        child: SafeArea(
          top: false,
          // FIX (white flash on auto-skip reappear — see the matching,
          // more detailed comment in main_shell.dart's bottomNavigationBar
          // for the full mechanism): wrapped in AnimatedSize +
          // AnimatedSwitcher instead of an instant SizedBox.shrink() ↔
          // MiniPlayer() swap, so the layout height change is smoothed
          // over real time rather than jumping in a single frame — that
          // single-frame jump was what let this Scaffold's implicit
          // Material fill flash visible for a beat.
          child: AnimatedSize(
            duration: AurumMotion.durationOrZero(AurumMotion.medium1),
            curve: AurumMotion.standard,
            alignment: Alignment.bottomCenter,
            child: Selector<PlayerProvider, bool>(
              selector: (_, p) => p.miniPlayerVisible,
              builder: (context, visible, __) => AnimatedSwitcher(
                duration: AurumMotion.durationOrZero(AurumMotion.medium1),
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
        ),
      ),
    );
  }
}
