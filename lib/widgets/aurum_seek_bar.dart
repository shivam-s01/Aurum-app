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

  // Wave shape constants — tuned to the "barely there" variant.
  static const double _wavelength = 26; // px per wave cycle
  static const double _waveSpeed = 14; // px per second, slow relaxed drift

  double _scrollX = 0;

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
  }

  @override
  void didUpdateWidget(_WaveformSeekBar old) {
    super.didUpdateWidget(old);
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
      // jump in _ampAnim/_scrollX on resume).
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
    final dtMs = (elapsed - _lastElapsed).inMilliseconds;
    _lastElapsed = elapsed;
    if (dtMs <= 0) return;
    final dt = (dtMs / 1000.0).clamp(0.0, 0.05);

    final playing = widget.player.isPlaying && !widget.dragging;

    // _scrollX advances every frame by real elapsed time (dt), same as any
    // smooth 60fps animation — it doesn't wait for a new position value to
    // move at all. The real position is only used to correct drift (seek,
    // resume, or the coarse position-ticker jumping further than one
    // frame's worth of travel), and even then it's blended in gently
    // rather than snapped, so a correction never reads as a visible jump.
    final targetScrollX = (widget.player.position.inMilliseconds / 1000.0) * _waveSpeed;
    if (playing) {
      _scrollX += dt * _waveSpeed;
      final drift = targetScrollX - _scrollX;
      final driftAbs = drift.abs();
      // Small gaps (normal position-ticker catch-up) blend in gently so
      // the correction is invisible. Large gaps — a new song starting, or
      // a seek landing far from where we were — snap immediately;
      // gradually blending a multi-second gap would show the wave visibly
      // crawling toward the correct spot for a second or more, which
      // reads as broken, not smooth.
      if (driftAbs > _waveSpeed * 3.0) {
        _scrollX = targetScrollX;
      } else if (driftAbs > _waveSpeed * 0.12) {
        _scrollX += drift * (dt * 4).clamp(0.0, 1.0);
      }
    } else {
      // Paused (or dragging): follow the real/seek position exactly so
      // the wave doesn't keep drifting on its own while audio is static.
      _scrollX = targetScrollX;
    }

    final target = playing ? 1.0 : 0.0;
    final nextAmp = _ampAnim + (target - _ampAnim) * (dt * 6).clamp(0.0, 1.0);

    // Thumb fraction: fast, slightly snappier ease (250ms-ish feel) so the
    // dot→capsule morph reads as a deliberate, responsive gesture reaction —
    // matches WavySliderExpressive's 250ms tween on thumbInteractionFraction.
    final thumbTarget = widget.dragging ? 1.0 : 0.0;
    final nextThumb =
        _thumbFraction + (thumbTarget - _thumbFraction) * (dt * 10).clamp(0.0, 1.0);

    final ampSettled = (nextAmp - _ampAnim).abs() <= 0.001 && !playing;
    final thumbSettled = (nextThumb - thumbTarget).abs() <= 0.001;

    if (!ampSettled || !thumbSettled || playing) {
      setState(() {
        _ampAnim = nextAmp;
        _thumbFraction = nextThumb;
      });
    } else if (_ticker.isTicking) {
      // Both eases reached their resting state — stop burning frames.
      setState(() {
        _ampAnim = nextAmp;
        _thumbFraction = thumbTarget;
      });
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
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
                // Only the horizontal-drag recognizer is registered here —
                // NOT onTapDown/onTapUp alongside it. A drag recognizer
                // alone already fires onHorizontalDragStart for a
                // zero-distance touch-and-release, so it covers plain taps
                // too — no separate tap handler needed, and no two-
                // recognizer arena race between tap and drag.
                onHorizontalDragStart: (d) {
                  widget.onDragStart();
                  handleUpdate(d.localPosition);
                },
                onHorizontalDragUpdate: (d) => handleUpdate(d.localPosition),
                onHorizontalDragEnd: (_) => widget.onDragEnd(widget.dragValue ?? progress),
                onHorizontalDragCancel: () => widget.onDragEnd(widget.dragValue ?? progress),
                child: CustomPaint(
                  size: Size(width, 32),
                  painter: _WaveformPainter(
                    progress: progress,
                    activeColor: widget.activeColor,
                    inactiveColor: widget.inactiveColor,
                    scrollX: _scrollX,
                    ampAnim: _ampAnim,
                    wavelength: _wavelength,
                    dragging: widget.dragging,
                    thumbInteractionFraction: _thumbFraction,
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

class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final double scrollX;
  final double ampAnim;
  final double wavelength;
  final bool dragging;
  final double thumbInteractionFraction; // 0 = idle dot, 1 = dragging capsule

  _WaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.scrollX,
    required this.ampAnim,
    required this.wavelength,
    required this.dragging,
    required this.thumbInteractionFraction,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final progressX = size.width * progress;
    final maxAmp = size.height * 0.10;
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

    double edgeFadeAt(double x) => (1.0 - ((progressX - x) / fadeZone)).clamp(0.0, 1.0);

    final activePath = Path();
    bool started = false;
    for (double x = 0; x <= waveEndX; x += 2) {
      final amp = maxAmp * ampAnim * edgeFadeAt(x) * (1.0 - f);
      final y = centerY + math.sin(k * (x - scrollX)) * amp;
      if (!started) {
        activePath.moveTo(x, y);
        started = true;
      } else {
        activePath.lineTo(x, y);
      }
    }

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
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
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(trackStartX, centerY),
        Offset(size.width - 5, centerY),
        trackPaint,
      );
      canvas.drawCircle(
        Offset(size.width - 2, centerY),
        1.8,
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
    final waveHeadY = centerY +
        math.sin(k * (progressX - scrollX)) * (maxAmp * ampAnim * edgeFadeAt(progressX) * (1.0 - f));
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
      old.scrollX != scrollX ||
      old.ampAnim != ampAnim ||
      old.dragging != dragging ||
      old.thumbInteractionFraction != thumbInteractionFraction;
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
