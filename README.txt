AURUM — Dynamic Island Fix — Files Changed
============================================

Place these 3 files at their EXACT same paths in your project
(they replace/overwrite existing files, except the new screen which is a NEW file):

1. lib/screens/island_customize_screen.dart   [NEW FILE]
   -> Full dedicated page (not a bottom sheet). Reached by tapping the
      "Dynamic Island" row in Settings -> Player & Audio.
   -> Real granular sliders: Horizontal Position (X), Vertical Position (Y),
      Island Width, Island Height, plus 7 accent color swatches, Reset to Defaults.
   -> Every change writes to SharedPreferences immediately and live-updates
      the overlay if it's already showing (AudioPrefs.updateIslandCustomization()).

2. lib/screens/settings_player_screen.dart     [REPLACE]
   -> Removed the old crash-prone bottom sheet (_showIslandCustomizeSheet)
      and its dead helper functions (_islandPositionLabel / _islandPositionKeyFromLabel).
   -> Removed unused fields (_islandPosition, _islandSizeScale, _islandAccentColor)
      that had no real effect anymore.
   -> "Dynamic Island" row now pushes IslandCustomizeScreen as a full page
      via AurumPageRoute (matches the app's existing navigation style),
      and refreshes its own state when you come back.

3. android/app/src/main/kotlin/com/aurum/music/AurumIslandService.kt   [REPLACE]
   -> Removed the old top_left/top_center/top_right + size-scale system.
   -> Added REAL X/Y offset + REAL width/height support, read from new
      SharedPreferences keys: island_x_dp, island_y_dp, island_width_dp,
      island_height_dp, island_accent_color.
   -> Added try/catch guards around every SharedPreferences read (safeFloat)
      so a corrupt/legacy value can NEVER crash the overlay — it silently
      falls back to a sane default instead.
   -> IMPORTANT FIX: the collapsed PILL is resizable (X/Y/width/height all
      apply to it). The EXPANDED card (full player-style panel with
      artwork/seekbar/controls/queue) keeps its natural size — forcing the
      same small width/height onto it would have clipped its own controls,
      which would have looked broken/awkward. Only position (X/Y) and
      accent color apply to the expanded card; size sliders only affect
      the pill, exactly like the reference screenshot you shared.

WHAT WAS CAUSING THE CRASH
---------------------------
The previous attempt (from the earlier session that hit its limit) had
created island_customize_screen.dart but never finished wiring it in —
the Settings row still called the OLD bottom sheet, and NOTHING in native
Kotlin understood the new dp-based keys yet. That mismatch, combined with
no defensive guards around SharedPreferences reads, is what the crash
report pointed to. This fix:
  - finishes the screen properly (full page, not a sheet)
  - wires the Settings row to it correctly
  - teaches native Kotlin the new keys, with try/catch on every read
  - keeps every slider's Dart-side range in sync with native's own
    coerceIn(...) bounds, so the UI never shows a value that gets
    silently clamped to something else behind the scenes
  - caps pill min-size above its actual content size so nothing ever
    visually clips

Re-run your GitHub Actions build after copying these files in.
