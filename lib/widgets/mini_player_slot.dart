import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../screens/main_shell.dart' show AurumBottomNavBar;
import 'mini_player.dart';

// ═══════════════════════════════════════════════════════════════════════
// MINI PLAYER SLOT — Spotify/YT Music-style "nav bar always visible, mini
// player shows/hides independently" behavior.
//
// PROBLEM THIS SOLVES: MainShell (Home/Search/Library) already shows the
// mini player + nav bar via its own bottomNavigationBar, because those 3
// screens live inside ONE persistent Scaffold via IndexedStack —
// switching tabs never tears that Scaffold down. But every
// content-browsing screen pushed via Navigator.push (Liked Songs,
// Downloads, History, Album, Artist, Mix, Playlists, Playlist Detail)
// builds its OWN separate Scaffold — MainShell's is now underneath it in
// the Navigator stack and its bottomNavigationBar is not part of that new
// Scaffold's layout at all. This slot reproduces both pieces so the nav
// bar is always reachable — exactly like Spotify/YT Music, where the nav
// bar is permanent chrome and only the mini player itself shows/hides
// based on whether something's playing. Only the actual full-screen Now
// Playing view (FullPlayerScreen) hides both entirely.
//
// USAGE: wrap whatever a pushed content screen would otherwise pass as
// `bottomNavigationBar:` — if that screen has none, just set
// `bottomNavigationBar: const MiniPlayerSlot()` directly on its Scaffold.
// Nothing else about the screen needs to change; this is a drop-in slot,
// not a screen rewrite.
//
// NAV TAPS FROM HERE: this screen is N levels deep in the Navigator stack
// on top of MainShell, which is the only widget that actually owns
// `_tab`/IndexedStack state. Tapping an icon here pops every route back
// down to MainShell first, then hands the tab switch to MainShell via
// PlayerProvider.requestNavTab — see that field's doc comment in
// player_provider.dart for the full reasoning. This mirrors how Spotify
// itself behaves: tapping Home from three screens deep lands you on the
// Home tab, it doesn't stack Home on top of where you were.
//
// Deliberately mirrors MainShell's exact bottomNavigationBar Material/
// RepaintBoundary wrapping instead of embedding the raw widgets directly
// — an earlier version of MainShell hit a "ghost pill" bug where
// Scaffold's bottomNavigationBar slot is always implicitly wrapped in an
// opaque Material by Flutter itself; skipping the same transparent-
// Material fix here would reintroduce that exact bug on every pushed
// screen instead of just MainShell. See main_shell.dart's matching
// comment for the full history.
// ═══════════════════════════════════════════════════════════════════════
class MiniPlayerSlot extends StatelessWidget {
  const MiniPlayerSlot({super.key});

  void _handleNavTap(BuildContext context, int barIndex) {
    // Pop this screen (and anything stacked above MainShell) off first,
    // so the tab switch lands on a MainShell that's actually back on
    // top — otherwise the IndexedStack would update invisibly underneath
    // whatever's still covering it.
    Navigator.of(context).popUntil((route) => route.isFirst);
    context.read<PlayerProvider>().requestNavTab(barIndex);
  }

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
            // FIX (Spotify-parity — matches the same fix in
            // main_shell.dart's bottomNavigationBar): only the mini
            // player itself hides when dismissed/nothing playing; the
            // nav bar below is always rendered regardless.
            //
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
            // currentIndex: -1 — no root tab is actually "active" on a
            // pushed content screen (we're not on Home/Search/Library
            // right now, we're on top of them), so nothing should show
            // the selected-tab highlight capsule. Any tap still
            // navigates correctly via _handleNavTap above; this only
            // affects which icon looks "selected".
            AurumBottomNavBar(
              currentIndex: -1,
              onTap: (barIndex) => _handleNavTap(context, barIndex),
            ),
          ],
        ),
      ),
    );
  }
}
