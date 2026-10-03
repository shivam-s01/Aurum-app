// ─────────────────────────────────────────────────────────────────────────────
// AurumSeekBar — the single shared seek bar used by EVERY full-player-style
// screen (Classic full player, Edge-to-Edge full player, and any future one).
//
// Before this file existed, the Edge-to-Edge screen had its own hand-rolled
// _ScrubBar that always rendered a plain Material Slider — it never looked
// at Settings → Appearance → "Player Slider Style" at all, so a user who
// picked "Waveform" (or Slim/Thick) saw it apply on the classic full player
// but NOT on Edge-to-Edge, which always showed the old default look
// regardless of setting. That's the bug this widget fixes: one seek bar
// implementation, imported by both screens, means the 4 styles (Slim,
// Thick, Rounded, Waveform) are visually and behaviorally identical no
// matter which full player screen is open.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../services/waveform_service.dart';

/// Drop-in seek bar: reads Settings → Appearance → "Player Slider Style"
/// itself and renders whichever of the 4 styles (Slim/Thick/Rounded/
/// Waveform) is selected — callers don't need to branch on style at all.
///
/// [activeColor]/[inactiveColor]/[timeColor] let each screen pass its own
/// palette (e.g. Edge-to-Edge's artwork-tinted accent vs the classic full
/// player's bgLuma-derived colors) while keeping the actual bar geometry,
/// animation, and interaction logic identical everywhere.
class AurumSeekBar extends StatefulWidget {
  final PlayerProvider player;
  final double hPad;
  final Color activeColor;
  final Color inactiveColor;
  final Color timeColor;

  /// Optional center widget rendered between the two time labels (Edge-to-
  /// Edge's "Astra" codec-style pill). Omit for the plain two-label layout.
  final Widget? centerLabel;

  const AurumSeekBar({
    super.key,
    required this.player,
    required this.hPad,
    required this.activeColor,
    required this.inactiveColor,
    required this.timeColor,
    this.centerLabel,
  });

  @override
  State<AurumSeekBar> createState() => _AurumSeekBarState();
}

class _AurumSeekBarState extends State<AurumSeekBar> {
  bool _dragging = false;
  double? _dragValue;
  List<double>? _waveform;
  String? _waveformFor;

  Future<void> _loadWaveform() async {
    final song = widget.player.currentSong;
    if (song == null) return;
    final key = song.localPath ?? song.streamUrl ?? song.id;
    if (_waveformFor == key) return;
    _waveformFor = key;
    final isLocal = song.isLocal;
    final path = song.localPath ?? song.streamUrl ?? '';
    if (path.isEmpty) return;
    final wf = await WaveformService.getWaveform(path, isLocal: isLocal);
    if (mounted && _waveformFor == key) {
      setState(() => _waveform = wf);
    }
  }

  @override
  Widget build(BuildContext context) {
    // PERF: listen to progress/position/buffered directly via Selector so
    // this bar updates every tick without dragging the rest of a heavier
    // parent screen along with it — same pattern the classic full player
    // already used, now shared by both screens.
    return Selector<PlayerProvider, (double, int, int, String, String, String?, bool)>(
      selector: (_, player) => (
        player.progress,
        player.duration.inMilliseconds,
        player.buffered.inMilliseconds,
        player.positionString,
        player.durationString,
        player.currentSong?.id,
        // Needed so the Waveform style's Ticker reliably restarts the
        // instant playback resumes, rather than depending on `progress`
        // happening to change on the same frame.
        player.isPlaying,
      ),
      builder: (context, data, __) => _buildSeekBar(context),
    );
  }

  Widget _buildSeekBar(BuildContext context) {
    final sliderStyle = context.watch<ThemeProvider>().playerSliderStyle;
    final double baseTrackHeight;
    final double thumbRadius;
    switch (sliderStyle) {
      case 'Slim':
        baseTrackHeight = 1.5;
        thumbRadius = 4.5;
        break;
      case 'Thick':
        baseTrackHeight = 6.0;
        thumbRadius = 7.0;
        break;
      case 'Waveform':
        baseTrackHeight = 0;
        thumbRadius = 0;
        break;
      case 'Rounded':
      default:
        baseTrackHeight = 3.0;
        thumbRadius = 5.5;
    }

    if (sliderStyle == 'Waveform') {
      _loadWaveform();
      return _WaveformSeekBar(
        player: widget.player,
        hPad: widget.hPad,
        waveform: _waveform,
        activeColor: widget.activeColor,
        inactiveColor: widget.inactiveColor,
        timeColor: widget.timeColor,
        dragging: _dragging,
        dragValue: _dragValue,
        centerLabel: widget.centerLabel,
        onDragStart: () => setState(() => _dragging = true),
        onDrag: (v) => setState(() => _dragValue = v),
        onDragEnd: (v) {
          widget.player.seek(v);
          setState(() {
            _dragging = false;
            _dragValue = null;
          });
        },
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad - 4),
      child: Column(children: [
        SizedBox(
          height: 32,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: _dragging ? baseTrackHeight + 1 : baseTrackHeight,
              thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _dragging ? thumbRadius + 2 : thumbRadius,
                  elevation: _dragging ? 4 : 1,
                  pressedElevation: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              activeTrackColor: widget.activeColor,
              inactiveTrackColor: widget.inactiveColor,
              thumbColor: widget.activeColor,
              overlayColor: widget.activeColor.withAlpha(22),
              trackShape: const _BufferedTrackShape(),
            ),
            child: Slider(
              value: _dragValue ?? widget.player.progress,
              secondaryTrackValue: widget.player.duration.inMilliseconds > 0
                  ? (widget.player.buffered.inMilliseconds /
                          widget.player.duration.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0.0,
              onChangeStart: (v) => setState(() {
                _dragging = true;
                _dragValue = v;
              }),
              onChanged: (v) => setState(() => _dragValue = v),
              onChangeEnd: (v) {
                widget.player.seek(v);
                setState(() {
                  _dragging = false;
                  _dragValue = null;
                });
              },
            ),
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.player.positionString,
                  style: TextStyle(
                      color: widget.timeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3)),
              if (widget.centerLabel != null) widget.centerLabel!,
              Text(widget.player.durationString,
                  style: TextStyle(
                      color: widget.timeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3)),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _WaveformSeekBar — Material 3 wavy progress indicator style.
// Track (unplayed) is a flat straight line; only the played portion waves.
// Wave phase is driven by actual audio position (ms), not a free-running
// timer, so it never drifts out of sync with playback, pause/resume, or
// seeking. Amplitude is intentionally small ("barely there") — this is the
// calmest of several tested variants and reads as premium, not gimmicky.
// ─────────────────────────────────────────────────────────────────────────────
class _WaveformSeekBar extends StatefulWidget {
  final PlayerProvider player;
  final double hPad;
  final List<double>? waveform;
  final Color activeColor;
  final Color inactiveColor;
  final Color timeColor;
  final bool dragging;
  final double? dragValue;
  final Widget? centerLabel;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onDragEnd;

  const _WaveformSeekBar({
    required this.player,
    required this.hPad,
    required this.waveform,
    required this.activeColor,
    required this.inactiveColor,
    required this.timeColor,
    required this.dragging,
    required this.dragValue,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    this.centerLabel,
  });

  @override
  State<_WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<_WaveformSeekBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _ampAnim = 0.0; // eases 0→1 on play, 1→0 on pause (flattens the wave)
  double _thumbFraction = 0.0; // eases 0→1 on drag start, 1→0 on drag end
  Duration _lastElapsed = Duration.zero;
  // PERF: bumped once per tick. The CustomPaint listens to this directly
  // (painter `repaint:`), so a frame repaints ONLY the bar's canvas —
  // no setState, no rebuild of the Column / time labels / parent tree.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  // Wave shape constants. Same model as Material 3 Expressive's
  // LinearWavyProgressIndicator: a fixed wavelength and a wave that travels
  // at a constant `waveSpeed` (dp/sec) independent of playback position.
  static const double _wavelength = 24; // px per wave cycle
  static const double _waveSpeed = 18; // px per second — calm, slow flow

  // FIX ("wave laggy — start se end tak smooth nahi"): the wave phase used
  // to be glued to player.position (a coarse 500ms-stepped value) and
  // re-corrected toward it every frame, so the wave visibly hitched every
  // time a new position landed. The phase is now FREE-RUNNING — it only
  // ever advances by (real frame dt * speed), never jumps, never looks at
  // the position. Pause/resume just stops/continues the same phase.
  double _phase = 0; // px, wrapped to [0, _wavelength)

  // FIX (thumb/wave-tip stepping): player.position only changes every
  // 500ms, so a thumb drawn straight from player.progress moves in
  // visible little steps. The ticker below interpolates between reports
  // (position + time since that report arrived) and eases toward it, so
  // the played-wave tip and the dot glide every frame.
  double _visMs = 0; // visual playback position, ms
  double _visFrac = 0; // _visMs / duration, 0..1
  int _lastReportedMs = -1;
  double _reportedAtMs = 0;
  final Stopwatch _clock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // Only actually ticking (60fps work) while playing. When the full
    // player is opened on a paused song, or the user pauses and leaves
    // the screen open, there is nothing left to animate once the wave has
    // flattened — running a Ticker every frame forever in that state is
    // pure wasted work (battery/heat) for a visually static line.
    if (widget.player.isPlaying && !widget.dragging) _ticker.start();
    _thumbFraction = widget.dragging ? 1.0 : 0.0;
    _visMs = widget.player.position.inMilliseconds.toDouble();
    _visFrac = widget.player.progress;
    _lastReportedMs = widget.player.position.inMilliseconds;
  }

  @override
  void didUpdateWidget(_WaveformSeekBar old) {
    super.didUpdateWidget(old);
    if (old.dragging && !widget.dragging) {
      // Drag just ended: player.seek() already set the position
      // optimistically, so land exactly where the finger left the thumb on
      // the very first frame (no one-frame flash of the pre-drag spot).
      _visMs = widget.player.position.inMilliseconds.toDouble();
      _visFrac = widget.player.progress;
      _lastReportedMs = widget.player.position.inMilliseconds;
      _reportedAtMs = _clock.elapsedMicroseconds / 1000.0;
    }
    _syncTickerToPlaybackState();
  }

  void _syncTickerToPlaybackState() {
    // Ticker also needs to run while a drag is in flight or just released,
    // purely to ease _thumbFraction — even if playback itself is paused.
    final settled = _ampAnim <= 0.001 &&
        (_thumbFraction - (widget.dragging ? 1.0 : 0.0)).abs() <= 0.001;
    final shouldRun =
        (widget.player.isPlaying && !widget.dragging) || widget.dragging || !settled;
    if (shouldRun && !_ticker.isTicking) {
      // Resuming from a stopped ticker: reset the elapsed baseline so the
      // next frame's dt isn't measured against a stale timestamp from
      // before the pause (which would otherwise produce one oversized
      // jump in _ampAnim/_phase on resume).
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!shouldRun && _ticker.isTicking) {
      // Only stop once both easings have actually settled — stopping
      // mid-ease would freeze the thumb/wave at an in-between shape
      // instead of settling to its resting state.
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final dtUs = (elapsed - _lastElapsed).inMicroseconds;
    _lastElapsed = elapsed;
    if (dtUs <= 0) return;
    // Clamp only protects against a huge hitch (app resumed from
    // background); normal frames pass through untouched.
    final dt = (dtUs / 1e6).clamp(0.0, 0.05);

    final player = widget.player;
    final playing = player.isPlaying && !widget.dragging;

    // 1) Wave phase — free-running, continuous, position-independent.
    if (playing || _ampAnim > 0.001) {
      _phase = (_phase + dt * _waveSpeed) % _wavelength;
    }

    // 2) Visual playback position — glides between 500ms position reports.
    if (!widget.dragging) {
      final durMs = player.duration.inMilliseconds;
      final nowMs = _clock.elapsedMicroseconds / 1000.0;
      final repMs = player.position.inMilliseconds;
      if (repMs != _lastReportedMs) {
        _lastReportedMs = repMs;
        _reportedAtMs = nowMs;
      }
      if (durMs > 0) {
        var posTarget = repMs.toDouble();
        if (playing) posTarget += (nowMs - _reportedAtMs).clamp(0.0, 600.0);
        posTarget = posTarget.clamp(0.0, durMs.toDouble());
        final err = posTarget - _visMs;
        if (err.abs() > 1500) {
          // Seek or new song: land exactly, no crawl.
          _visMs = posTarget;
        } else {
          // Frame-rate independent ease toward the interpolated target.
          _visMs += err * (1 - math.exp(-dt * 12));
        }
        _visFrac = (_visMs / durMs).clamp(0.0, 1.0);
      } else {
        _visMs = 0;
        _visFrac = 0;
      }
    }

    // 3) Amplitude / thumb easing — frame-rate independent exponentials.
    final ampTarget = playing ? 1.0 : 0.0;
    final nextAmp = _ampAnim + (ampTarget - _ampAnim) * (1 - math.exp(-dt * 6));

    // Thumb fraction: fast, snappy ease so the dot→capsule morph reads as a
    // deliberate reaction to touch (matches WavySliderExpressive's tween).
    final thumbTarget = widget.dragging ? 1.0 : 0.0;
    final nextThumb =
        _thumbFraction + (thumbTarget - _thumbFraction) * (1 - math.exp(-dt * 12));

    final ampSettled = (nextAmp - ampTarget).abs() <= 0.002 && !playing;
    final thumbSettled = (nextThumb - thumbTarget).abs() <= 0.002;

    if (playing || !ampSettled || !thumbSettled) {
      _ampAnim = nextAmp;
      _thumbFraction = nextThumb;
      _frame.value++;
    } else if (_ticker.isTicking) {
      // Everything reached its resting state — stop burning frames.
      _ampAnim = ampTarget;
      _thumbFraction = thumbTarget;
      _frame.value++;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Playback state can change (play/pause, drag start/end) without a
    // new widget instance being created, so this check needs to run on
    // every build too, not just didUpdateWidget — covers the case where
    // only a field the ticker cares about changed via setState elsewhere
    // in the parent without the widget identity changing.
    _syncTickerToPlaybackState();
    final progress =
        widget.dragging ? (widget.dragValue ?? widget.player.progress) : widget.player.progress;
    if (!_ticker.isTicking && !widget.dragging) {
      // Idle (paused/settled): the bar simply shows the real position.
      _visFrac = widget.player.progress;
      _visMs = widget.player.position.inMilliseconds.toDouble();
      _lastReportedMs = widget.player.position.inMilliseconds;
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad - 4),
      child: Column(children: [
        SizedBox(
          height: 32,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              void handleUpdate(Offset local) {
                final v = (local.dx / width).clamp(0.0, 1.0);
                widget.onDrag(v);
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // FIX ("sidha click karo toh seek nahi hota, sirf pakad
                // kar drag karne pe hi kaam karta hai"): only the
                // horizontal-drag recognizer was registered here — no
                // tap handler. The old assumption was that a drag
                // recognizer alone also resolves a zero-distance
                // touch-and-release as a "start", so a plain tap would
                // be covered for free. It isn't: onHorizontalDragStart
                // only fires once the gesture arena actually resolves a
                // drag (real horizontal movement past the touch slop),
                // so a genuine tap — finger down, no movement, straight
                // back up — never fires it at all. That's exactly why
                // tapping anywhere on the bar did nothing while dragging
                // worked fine. Adding onTapUp alongside the drag
                // handlers lets GestureDetector run both recognizers in
                // the same arena and resolve whichever one actually
                // matches the gesture — a tap seeks immediately via
                // onTapUp, a drag still seeks continuously as before;
                // this is the same pattern Flutter's own Slider uses
                // internally to support both tap-to-seek and drag.
                onTapUp: (d) {
                  final v = (d.localPosition.dx / width).clamp(0.0, 1.0);
                  widget.onDragStart();
                  widget.onDrag(v);
                  widget.onDragEnd(v);
                },
                onHorizontalDragStart: (d) {
                  widget.onDragStart();
                  handleUpdate(d.localPosition);
                },
                onHorizontalDragUpdate: (d) => handleUpdate(d.localPosition),
                onHorizontalDragEnd: (_) => widget.onDragEnd(widget.dragValue ?? progress),
                onHorizontalDragCancel: () => widget.onDragEnd(widget.dragValue ?? progress),
                // RepaintBoundary: the wave animates at 60fps in its own
                // layer, so the rest of the player never repaints with it.
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: Size(width, 32),
                    painter: _WaveformPainter(
                      repaint: _frame,
                      // Read at PAINT time (not build time), so every
                      // ticker frame draws the newest wave state without
                      // rebuilding any widget.
                      live: () => (_phase, _ampAnim, _thumbFraction, _visFrac),
                      progress: progress,
                      activeColor: widget.activeColor,
                      inactiveColor: widget.inactiveColor,
                      wavelength: _wavelength,
                      dragging: widget.dragging,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.player.positionString,
                  style: TextStyle(
                      color: widget.timeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3)),
              if (widget.centerLabel != null) widget.centerLabel!,
              Text(widget.player.durationString,
                  style: TextStyle(
                      color: widget.timeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3)),
            ],
          ),
        ),
      ]),
    );
  }
}

// Height of the thumb's bob relative to the full wave (0..1).
const double _thumbAmpScale = 0.6;

class _WaveformPainter extends CustomPainter {
  final (double, double, double, double) Function() live; // phase, ampAnim, thumbFrac, visProgress
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final double wavelength;
  final bool dragging;

  _WaveformPainter({
    required Listenable repaint,
    required this.live,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.wavelength,
    required this.dragging,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final (scrollX, ampAnim, thumbInteractionFraction, visProgress) = live();
    final centerY = size.height / 2;
    // While dragging the finger owns the position; otherwise use the
    // per-frame interpolated one so the tip/thumb glide instead of
    // stepping every 500ms.
    final shownProgress = dragging ? progress : visProgress;
    final progressX = (size.width * shownProgress).clamp(0.0, size.width);
    // Livelier amplitude (was height * 0.10 ≈ 3.2px on a 32px bar, which
    // read as "barely moving"): now ≈ 4px at full play — visible flow,
    // still calm and premium.
    final maxAmp = size.height * 0.125;
    final k = (2 * math.pi) / wavelength;
    final f = thumbInteractionFraction; // shorthand

    // Gap around the thumb grows while dragging — matches the Kotlin
    // WavySliderExpressive's dynamicGapSize: a small idle gap that eases
    // into a wider one sized to the capsule thumb while interacting, so
    // the thumb never overlaps the track/wave.
    final idleGap = 5.0;
    final draggingGap = 11.0 + (maxAmp * ampAnim);
    final gap = idleGap + (draggingGap - idleGap) * f;

    // Thumb geometry: idle = small round dot, dragging = the Material3
    // Expressive "capsule" (short thick rounded-rect standing upright) —
    // straight port of the Kotlin file's currentWidth/currentHeight lerp.
    final idleThumbSize = 8.0;
    final draggingThumbWidth = 4.0;
    final draggingThumbHeight = 20.0;
    final thumbWidth = idleThumbSize + (draggingThumbWidth - idleThumbSize) * f;
    final thumbHeight = idleThumbSize + (draggingThumbHeight - idleThumbSize) * f;

    // --- Active (played) wave -------------------------------------------------
    // Amplitude fades to 0 over the last ~0.85 wavelengths before the
    // PLAYHEAD (progressX) — not before the gap-adjusted waveEndX. Using
    // progressX as the single fade reference point means the path and the
    // dot below both evaluate the exact same edgeFade curve, so the dot
    // always lands precisely on the wave's continuation instead of using
    // a different (full-amplitude) formula that floated it off the line.
    final fadeZone = wavelength * 0.85;
    final waveEndX = (progressX - gap / 2).clamp(0.0, size.width);

    // Path amp eases from FULL (behind) to _thumbAmpScale (at the thumb)
    // across the fade zone, so the line glides into the dot's softer bob.
    double edgeFadeAt(double x) {
      final t = ((progressX - x) / fadeZone).clamp(0.0, 1.0); // 0 at head
      return _thumbAmpScale + (1.0 - _thumbAmpScale) * t;
    }

    final activePath = Path();
    bool started = false;
    // Sample every 2px, then ALWAYS finish exactly on waveEndX. The old
    // loop stopped up to 2px short, so the wave tip moved in 2px steps
    // while the thumb moved smoothly — a visible stutter at the head.
    double yAt(double x) {
      final amp = maxAmp * ampAnim * edgeFadeAt(x) * (1.0 - f);
      return centerY + math.sin(k * (x - scrollX)) * amp;
    }

    double lastX = 0;
    for (double x = 0; x < waveEndX; x += 2) {
      final y = yAt(x);
      if (!started) {
        activePath.moveTo(x, y);
        started = true;
      } else {
        activePath.lineTo(x, y);
      }
      lastX = x;
    }
    if (waveEndX > 0 || started) {
      final yEnd = yAt(waveEndX);
      if (!started) {
        activePath.moveTo(waveEndX, yEnd);
        started = true;
      } else if (waveEndX > lastX) {
        activePath.lineTo(waveEndX, yEnd);
      }
    }

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (started) canvas.drawPath(activePath, activePaint);

    // --- Inactive (unplayed) track ---------------------------------------------
    // Flat line starting after the thumb gap, ending in a rounded stop —
    // matches LinearWavyProgressIndicator's stopSize dot from the Kotlin
    // WavySliderExpressive.
    final trackStartX = (progressX + gap / 2).clamp(0.0, size.width);
    if (trackStartX + 4 < size.width) {
      final trackPaint = Paint()
        ..color = inactiveColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(trackStartX, centerY),
        Offset(size.width - 6, centerY),
        trackPaint,
      );
      canvas.drawCircle(
        Offset(size.width - 2, centerY),
        2.0,
        Paint()..color = inactiveColor,
      );
    }

    // --- Thumb -------------------------------------------------------------
    // At f=0 this is the wave-riding dot; as f→1 it morphs into an upright
    // capsule that no longer follows the (now-flattened) wave's y, easing
    // toward centerY — same idle-dot → capsule morph as the Kotlin
    // version's Canvas thumb draw.
    //
    // Dot sits AT progressX and uses edgeFadeAt(progressX) — the SAME
    // function the path used for every one of its points — so the dot is
    // always the mathematical continuation of the line beneath it, never
    // a separately-computed value that can visibly disagree with where
    // the path actually ends.
    // Thumb bob: the dot sits on the wave's exact continuation (same
    // sine, same phase, same amplitude as the path's last point) but at
    // ~60% of its height — a soft, small up/down that feels alive without
    // ever jumping off the line — and eases to dead-center as it morphs
    // into the drag capsule. The played wave's own last stretch fades
    // toward that same reduced height (see _thumbAmpScale below), so the
    // dot and line always meet cleanly.
    final waveHeadY = centerY +
        math.sin(k * (progressX - scrollX)) *
            (maxAmp * ampAnim * _thumbAmpScale * (1.0 - f));
    final headY = waveHeadY * (1.0 - f) + centerY * f;

    final thumbPaint = Paint()..color = activeColor;
    final rect = Rect.fromCenter(
      center: Offset(progressX, headY),
      width: thumbWidth,
      height: thumbHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(thumbWidth / 2)),
      thumbPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.dragging != dragging;
}

// Buffered/preloaded region overlay for the Slim/Thick/Rounded (plain
// Material Slider) styles — draws a subtle filled rect between the track
// start and the secondary (buffered) offset, so users can see how much of
// the song is preloaded ahead of playback, not just current progress.
class _BufferedTrackShape extends RoundedRectSliderTrackShape {
  const _BufferedTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(context, offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        textDirection: textDirection,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isDiscrete: isDiscrete,
        isEnabled: isEnabled,
        additionalActiveTrackHeight: additionalActiveTrackHeight);

    if (secondaryOffset != null) {
      final trackRect = getPreferredRect(
          parentBox: parentBox,
          offset: offset,
          sliderTheme: sliderTheme,
          isEnabled: isEnabled,
          isDiscrete: isDiscrete);
      final paint = Paint()
        ..color = Colors.white.withAlpha(40)
        ..style = PaintingStyle.fill;
      final bufferedRect = Rect.fromLTRB(
          trackRect.left, trackRect.top, secondaryOffset.dx, trackRect.bottom);
      context.canvas.drawRRect(
          RRect.fromRectAndRadius(bufferedRect, const Radius.circular(2)),
          paint);
    }
  }
}
