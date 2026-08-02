#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Aurum — Auto Sleep Guard fix — ONE-SHOT push script
# Uses ONLY: ~/storage/downloads/aurum-fixed.zip  (the "just now" one)
# Ignores every other zip in Downloads.
# =============================================================================
set -e

ZIP=~/storage/downloads/aurum-fixed.zip
REPO=~/Aurum-app
WORK=~/aurum-fixed-extract

echo "== Aurum fix — one-shot push =="

if [ ! -f "$ZIP" ]; then
  echo "ERROR: $ZIP not found. Make sure aurum-fixed.zip is in Downloads."
  exit 1
fi

echo "-> using zip: $ZIP"

echo "-> extracting"
rm -rf "$WORK"
mkdir -p "$WORK"
unzip -oq "$ZIP" -d "$WORK"

cd "$REPO"

echo "-> copying files into repo"
cp "$WORK/android/app/src/main/kotlin/com/aurum/music/AurumEngineChannelHandler.kt" \
   android/app/src/main/kotlin/com/aurum/music/AurumEngineChannelHandler.kt

cp "$WORK/android/app/src/main/kotlin/com/aurum/music/AutoSleepGuard.kt" \
   android/app/src/main/kotlin/com/aurum/music/AutoSleepGuard.kt

cp "$WORK/lib/widgets/auto_sleep_guard_tile.dart" \
   lib/widgets/auto_sleep_guard_tile.dart

cp "$WORK/lib/l10n/app_en.arb" \
   lib/l10n/app_en.arb

cp "$WORK/lib/services/native_engine_bridge.dart" \
   lib/services/native_engine_bridge.dart

echo "-> staging only these 5 files"
git add \
  android/app/src/main/kotlin/com/aurum/music/AurumEngineChannelHandler.kt \
  android/app/src/main/kotlin/com/aurum/music/AutoSleepGuard.kt \
  lib/widgets/auto_sleep_guard_tile.dart \
  lib/l10n/app_en.arb \
  lib/services/native_engine_bridge.dart

echo "-> git status (should show only these 5 files staged)"
git status

echo "-> commit"
git commit -m "fix: Auto Sleep Guard always-on (3h default) + Are-you-awake confirm flow, Android 10+ safe"

echo "-> push"
git push origin main

echo "-> cleanup"
rm -rf "$WORK"

echo "== Done. Build will start automatically: =="
echo "   https://github.com/shivam-s01/Aurum-app/actions"
