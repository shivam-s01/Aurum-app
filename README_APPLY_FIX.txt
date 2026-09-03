AURUM — SPLASH FIX + 8 ADDITIONAL FIXES (combined) — apply instructions
==========================================================================

This zip mirrors your repo's own folder structure. From your repo root
(~/Aurum-app in Termux):

    cd ~/Aurum-app
    cp -r ~/storage/downloads/<this-unzipped-folder>/* .

    # Delete files that must be removed (not just replaced):
    rm -f lib/screens/splash_screen.dart
    rm -f android/app/src/main/res/values-v31/styles.xml
    rmdir android/app/src/main/res/values-v31 2>/dev/null

    git add -A
    git commit -m "fix: native-only splash (matches Echo Nightly exactly) + 8 additional fixes (player, cache freshness, home/library/liked/mix screens, audio output sheet, audio engine)"
    git push

WHAT'S IN THIS ZIP (12 files)
--------------------------------

SPLASH FIX (5 files):
  lib/main.dart
    Dart-side splash overlay removed entirely from the widget tree.
  assets/images/note_glyph.png
    Traced pixel-perfect from your own scallop_ring.png's note-shaped
    cutout (not used by the splash anymore, kept in case useful).
  android/app/src/main/res/drawable/art_splash_anim.xml
    The ONLY splash animation now — native, 900ms, ring/note/bg
    choreography percentage-matched to Echo Nightly's own
    art_splash_anim.xml. Verified: every animator boundary continuous
    (no snaps/jumps), ends exactly at 900ms, within Android's 1000ms
    hard cap.
  android/app/src/main/res/values/styles.xml
    windowSplashScreenAnimatedIcon set directly (Echo's own approach —
    no MIUI-avoidance workaround, which was actually causing the
    "static icon, nothing animates" symptom).
  android/app/src/main/kotlin/com/aurum/music/MainActivity.kt
    setTheme(NormalTheme) moved to AFTER super.onCreate() so it no
    longer hijacks the native splash's own theme resolution.

  ROOT CAUSE RECAP — why the splash wasn't showing/animating at all:
    1. windowSplashScreenAnimatedIcon was left unset → MIUI fell back
       to its own default (bare static launcher icon, no animation).
    2. setTheme() ran before super.onCreate() → told Android to use
       NormalTheme (which has zero splash config) as the splash theme.
    3. A leftover values-v31/styles.xml override cleared the icon back
       to unset on API 31+ regardless of the above two fixes.
    4. Dart-side SplashScreen ran ITS OWN separate 2400ms animation
       AFTER the native 900ms one finished — two animations back to
       back, ~3.3s total, with a visible restart/glitch in the middle.
       Fixed by removing the Dart-side splash entirely — exactly one
       native 900ms animation now, same as Echo Nightly (which has no
       Dart/Compose-side splash at all).
    5. A real animator bug: the ring's second rotation burst had
       valueFrom="0" instead of "120", causing a visible snap-back
       mid-animation. Fixed.

8 ADDITIONAL FIXES (as provided):
  lib/services/home_feed_cache.dart
    Cache freshness restored to a 6-hour window (isFresh()/
    isArtistsFresh()/isPlaylistsFresh() gate background re-fetch on
    this; instant-paint-from-cache on cold start is unaffected either
    way). NOTE: this file also touches the splash fix above (it had a
    stale comment referencing the now-deleted splash_screen.dart) —
    only that one comment was corrected; the 6-hour freshness logic
    itself is untouched from what you provided.
  lib/providers/player_provider.dart
  lib/screens/liked_screen.dart
  lib/screens/library_screen.dart
  lib/screens/home_screen.dart
  lib/screens/mix_screen.dart
  lib/widgets/audio_output_sheet.dart
  android/app/src/main/kotlin/com/aurum/music/AurumAudioEngine.kt
    Applied as provided — no conflicts found with the splash fix
    (cross-checked: no other file references splash_screen.dart,
    art_splash_anim.xml, MainActivity's theme handling, or
    _SplashOnEveryEntry).

VERIFICATION PERFORMED ON THIS BATCH
---------------------------------------
- All Dart/Kotlin files checked for brace/paren balance with strings
  and comments properly stripped first (naive raw counting gives false
  positives when a { or } appears inside a string literal or comment —
  confirmed and ruled out for player_provider.dart and home_screen.dart,
  both are actually balanced).
- All XML files re-validated as well-formed.
- Cross-checked all 8 new files for any reference to the splash system
  — only home_feed_cache.dart had one stale comment, now fixed.
- art_splash_anim.xml's animator timeline re-verified: zero
  discontinuities, zero overlaps, ends at exactly 900ms.
