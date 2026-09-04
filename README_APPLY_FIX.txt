AURUM SPLASH FIX (v3 — compat library for Realme UI) — apply instructions
==============================================================================

WHAT CHANGED
-------------
The raw platform SplashScreen attributes (windowSplashScreenAnimatedIcon
etc.) were confirmed byte-identical to Echo Nightly's own working
values/themes.xml setup, but were silently falling back to the bare
static launcher icon specifically on Realme UI 6.0 (Android 15) — even
though the logo shape distortion (missing evenOdd fillType) was
already fixed in the previous round.

Switched to androidx.core.splashscreen — Google's official compat
library, specifically built to normalize this kind of per-OEM
inconsistency in how the platform SplashScreen API gets honored.

HOW TO APPLY
-------------
    cd ~/Aurum-app
    cp -r ~/storage/downloads/<this-unzipped-folder>/* .

    git add -A
    git commit -m "fix: splash showed static launcher icon on Realme UI (Android 15) — switched to androidx.core.splashscreen compat library"
    git pull --rebase origin main
    git push

FILES IN THIS ZIP (4 files)
------------------------------
  android/app/build.gradle
    Added androidx.core:core-splashscreen:1.0.1 dependency.
  android/app/src/main/res/values/styles.xml
    LaunchTheme's parent changed from a plain framework theme to
    Theme.SplashScreen (provided by the compat library itself — no
    extra AppCompat/Material dependency needed). Same 4 core attributes
    (background, icon, duration, post-splash theme) as before, just
    without the android: prefix and tools:targetApi gating, since the
    compat library backports these itself.
  android/app/src/main/kotlin/com/aurum/music/MainActivity.kt
    Added installSplashScreen() call, required before super.onCreate().
    This also now handles the postSplashScreenTheme switch automatically
    — the old manual setTheme(R.style.NormalTheme) call was removed to
    avoid two code paths managing the same transition.
  android/app/src/main/res/drawable/art_splash_anim.xml
    Unchanged from the previous round — included here so this zip is a
    complete, drop-in set. Already has the evenOdd fillType fix (ring
    and note-hole shape correctness) and the leading-comment-moved-
    after-root-element fix from the earlier round.

WHY THIS SHOULD FIX IT
-------------------------
The compat library sits between the theme and the raw platform API. On
API 31+ it still delegates to the real platform SplashScreen under the
hood — but it also independently verifies the icon actually gets set,
and falls back to drawing the splash itself via a plain View if the
platform doesn't cooperate. This is the standard, Google-recommended
migration path (see developer.android.com's own splash-screen
migration guide) specifically for this class of OEM inconsistency —
not a workaround specific to Aurum.

IF THIS STILL DOESN'T WORK
-----------------------------
That would mean Realme UI's fallback view is also somehow not
rendering the animated vector correctly, which would need a build log
+ a fresh screenshot to diagnose further — at that point the next step
would be testing on a non-Realme device to confirm whether this is
genuinely device-specific or something broader.
