AURUM — ALL FIXES — CHANGED FILES ONLY (6 files) — FINAL RECHECKED PASS
==========================================================================

HOW TO APPLY:
Copy each file into your project at the exact same path, overwriting
the existing one:

  lib/providers/player_provider.dart             → REPLACE
  lib/screens/settings_screen.dart                → REPLACE
  lib/screens/settings_storage_screen.dart        → REPLACE
  lib/screens/settings_about_screen.dart          → REPLACE
  lib/screens/onboarding_screen.dart              → REPLACE
  lib/screens/edge_to_edge_full_player.dart       → REPLACE

DELETE THIS FILE FROM YOUR PROJECT (not included here — just delete it):

  lib/screens/settings_notifications_screen.dart  → DELETE

This is a final, fully rechecked pass. Every file was re-read top to
bottom, every AurumTheme/AuthProvider method call verified to actually
exist with that exact name, every gesture's math worked through by
hand (delta signs, snap-stop logic), and a proper string-aware bracket
balance check (correctly handles apostrophes inside comments/strings,
unlike a naive character count) run on all 6 — all clean.

Two additional issues were caught and fixed during this final pass
(beyond what was already fixed before):
  - settings_screen.dart: the account avatar widget checked url-
    presence but not the signedIn flag — a defensive fix now makes a
    signed-out state never show an avatar image, even hypothetically.
  - edge_to_edge_full_player.dart: the sheet drag-handle's gesture
    handlers now guard on controller.isAttached before touching
    .size/.jumpTo()/.animateTo() — calling those before the controller
    finishes attaching throws an assertion, which an extremely fast
    drag right as the sheet opens could otherwise hit.

========================================
1. settings_screen.dart — Main Settings screen redesign
========================================
  - Added an account anchor card at the top (avatar/initial, name,
    email or "Tap to sign in") — matches Spotify's settings header.
    Tapping it opens the existing ProfileScreen.
  - Large collapsing title (Apple Music / Spotify style): big title at
    rest, shrinks smoothly to a small pinned title on scroll. Built on
    a raw SliverPersistentHeader (not SliverAppBar + FlexibleSpaceBar)
    to avoid a double-animation glitch where the title would shrink
    twice at slightly different rates and look like a stutter.
  - Icons now sit in a soft tonal container instead of bare glyphs —
    the Spotify/Apple Music treatment.
  - Removed the "Notifications" row (its screen is deleted — see #4).
  - Removed a dead flutter/services.dart import.
  - Avatar now explicitly guards on signedIn, not just url-presence.

========================================
2. settings_storage_screen.dart
========================================
  - Removed the entire "Song Cache" section — no song-caching
    mechanism exists anywhere in the app for it to control. Downloads
    and Image Cache sections untouched, confirmed fully functional.
  - Crash fix: _clearDir() and _clearDownloads() ran delete()/exists()
    with no try/catch, unlike every other file-I/O path in this
    screen. A locked file, permission hiccup, or a directory vanishing
    mid-check could throw uncaught — and since the throw happens
    before _load() runs (which flips the loading spinner off), the
    screen would get stuck permanently loading. Both now wrap the
    delete in try/catch.

========================================
3. settings_about_screen.dart
========================================
  - Removed the "Diagnostics" section (Export/Clear Diagnostic Log) —
    a developer debug tool explicitly marked "DIAGNOSTIC (temporary)"
    in the code, not meant to ship to end users. The background
    logging service itself was left untouched (used elsewhere for
    crash/error tracking).
  - Removed the now-unused diagnostic_log_service.dart import.

========================================
4. settings_notifications_screen.dart — DELETE THIS FILE
========================================
  - Every setting on this screen saved to SharedPreferences but was
    never read by the native Android notification code — confirmed
    non-functional. Screen removed entirely; its row also removed
    from the main Settings list (see #1).

========================================
5. onboarding_screen.dart — FIX: onboarding repeating after skip
========================================
  Root cause: _finish() saved the 'onboarding_complete' flag inside a
  try/catch that silently swallowed any failure, then called onDone()
  unconditionally right after regardless of whether the save actually
  succeeded — so a failed write meant the current session looked fine,
  but the next app open replayed the whole onboarding flow again.

  Fix: _finish() now retries the write up to 3 times with a short
  delay, and reads the flag back afterward to actually confirm it was
  saved before proceeding to Home.

========================================
6. edge_to_edge_full_player.dart — FIX: Up Next sheet snapping back
========================================
  Root cause: the Up Next DraggableScrollableSheet and the
  ReorderableListView inside it shared one ScrollController. A
  ReorderableListView/ListView claims the vertical drag gesture for
  itself the instant a touch starts over its content, regardless of
  controller sharing — so dragging to resize the sheet was almost
  always read as "scroll/reorder the list" instead, and the sheet
  snapped back to its original size a moment later because no real
  resize drag was ever recognized. The visible drag handle bar was
  also purely decorative with no gesture attached at all.

  Fix: the sheet now gets its own explicit
  DraggableScrollableController, fully decoupled from the list (which
  gets its own independent ScrollController). The handle bar at the
  top is now a real resize target — drag it to resize live, release to
  snap to the nearest of three stops (0.5 / 0.82 / 0.94), matching
  YouTube's own Up Next handle behavior. Dragging over the list still
  scrolls/reorders normally with no competition. Also fixed a memory
  leak (the sheet controller wasn't being disposed), and both drag
  handlers now guard on controller.isAttached before touching
  .size/.jumpTo()/.animateTo() to avoid a possible assertion crash on
  an extremely fast drag right as the sheet opens.

========================================
7. player_provider.dart — 2 verified fixes (surfaced from your upload)
========================================
  a) Stale-event guard extended to position/duration/buffered
     Root cause: on a song switch, _isLoading was already protected by
     an isStaleForLoading check (only accept it from an event actually
     describing the expected new song), but _position/_duration/
     _buffered were applied completely unconditionally in that same
     spot. A stale/in-flight event still describing the OLD song
     landed there first and clobbered the optimistic reset back to the
     old song's values, which then briefly rendered under the NEW
     song's (correctly optimistic) title/artwork before the real
     new-song event corrected it a beat later.

     Fix: position/duration/buffered are now only accepted under the
     same isStaleForLoading guard already protecting isLoading — this
     final pass confirmed isStaleForLoading and the later
     isConfirmedSwitch check are logically equivalent (De Morgan's
     law), so the guard is consistent with the rest of the function,
     not a mismatched duplicate condition. The position-handling call
     that used to run later was moved up into this guarded block, with
     a comment left at its old location — no duplicate calls.

  b) Seek bar "drag awkward" fix — optimistic position update
     Root cause: seek(ratio) awaited the native engine call before
     _position was ever updated, so after a drag ended the Slider fell
     back to reading the OLD position for a beat before the new
     position arrived — reading as "the bar jumps back to where I
     started dragging, then snaps to where I actually dragged to."

     Fix: both seek(ratio) and seekTo(pos) now set _position and call
     notifyListeners() optimistically before awaiting the native seek.
