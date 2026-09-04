AURUM SPLASH FIX — COMPLETE SET (compat library + windowBackground fix)
============================================================================

This is a complete, self-sufficient set — includes everything from the
v3 (compat library) and v4 (windowBackground removal) fixes together.
No need to apply multiple zips — just this one.

TWO ROOT CAUSES FOUND AND FIXED
----------------------------------
1. Realme UI (Android 15) wasn't honoring the raw platform
   windowSplashScreenAnimatedIcon attribute even though it was
   byte-identical to Echo Nightly's own working setup — fixed by
   adding androidx.core.splashscreen, Google's official compat library
   built specifically to normalize this kind of per-OEM inconsistency.

2. LaunchTheme was ALSO setting android:windowBackground
   (@drawable/launch_background) alongside the new
   windowSplashScreenBackground attribute. Android's own SplashScreen
   migration docs state explicitly that doing this makes the system
   discard your custom splash and fall back to its own default — the
   bare static launcher icon on an adaptive-icon card. This is exactly
   what the screenshots showed, and it would have blocked the
   animation even with the compat library in place, since this
   conflict sits upstream of it. Confirmed by checking that Echo
   Nightly's own working theme never sets android:windowBackground on
   its splash theme.

HOW TO APPLY
-------------
    cd ~/Aurum-app
    cp -r ~/storage/downloads/<this-unzipped-folder>/* .

    git add -A
    git commit -m "fix: splash showed static launcher icon on Realme UI — added core-splashscreen compat library + removed conflicting windowBackground override"
    git pull --rebase origin main
    git push

FILES IN THIS ZIP (4 files)
------------------------------
  android/app/build.gradle
    androidx.core:core-splashscreen:1.0.1 dependency added.
  android/app/src/main/res/values/styles.xml
    LaunchTheme parent changed to Theme.SplashScreen (compat library's
    theme). android:windowBackground REMOVED from LaunchTheme (the
    actual fix). postSplashScreenTheme points to NormalTheme.
  android/app/src/main/kotlin/com/aurum/music/MainActivity.kt
    installSplashScreen() called before super.onCreate(), as required.
  android/app/src/main/res/drawable/art_splash_anim.xml
    Unchanged from the previous round — the logo shape fix (evenOdd
    fillType, correctly cutting the note-shaped hole from the ring)
    and the full Echo-matched 900ms timeline are both already in this
    file. Re-verified: zero animator discontinuities, ends at exactly
    900ms, well within Android's hard splash duration cap.

WHAT TO EXPECT
----------------
The scallop-ring logo (your actual scallop_ring.png shape, traced to
vector) should now animate on the native OS splash screen, exactly
once, for 900ms, with:
  - the ring rotating in two smooth bursts (net 240°)
  - the note glyph tilting and popping independently
  - a soft background glow rotating underneath
No static launcher-icon fallback, no double-icon effect, no
distortion.

IF THIS STILL DOESN'T WORK
-----------------------------
At that point the issue would most likely be something specific to
Realme UI's SplashScreen implementation that neither the raw platform
API nor the compat library can work around from the app side — the
next diagnostic step would be testing the exact same APK on a
non-Realme device to confirm whether the animation works correctly
there, which would isolate the problem to Realme UI specifically
rather than anything in Aurum's own code.
