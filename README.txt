SHUFFLE + REPEAT BUTTONS — PREMIUM MOTION REFINEMENT (v3)

1. full_player_screen.dart -> lib/screens/full_player_screen.dart

Keeps the exact same restrained visual language from v2 (no pill, no
glow, no shadow — just the icon color + a small dot). This pass refines
the MOTION quality only:
   - Icon color now animates smoothly (260ms easeOutCubic) between
     muted/gold when toggling, instead of snapping instantly.
   - The active dot now scales in with a slight overshoot (easeOutBack)
     instead of a flat fade-in — reads as a confident "settle" rather
     than just appearing.
   - Icon shape swap (repeat -> repeat-one) now pairs a fade with a
     subtle scale for a slightly softer transition.

This fully replaces all previous _CtrlBtn versions — apply on top of a
clean full_player_screen.dart (this zip contains the complete file).

HOW TO APPLY + PUSH (Termux):

    cd ~/Aurum-app
    unzip -o /sdcard/Download/shuffle-repeat-redesign-v3.zip -d .
    git add lib/screens/full_player_screen.dart
    git commit -m "polish: smoother color/scale transitions on shuffle/repeat active state"
    git push origin main
