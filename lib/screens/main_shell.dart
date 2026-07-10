import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../theme/aurum_theme.dart';
import '../widgets/mini_player.dart';
import '../models/song.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import '../providers/player_provider.dart';
import '../services/update_service.dart';
import '../services/local_music_service.dart';
import '../services/audio_prefs.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _tab = 0;

  final _homeKey = GlobalKey<State<HomeScreen>>();

  late final _screens = [
    HomeScreen(key: _homeKey),
    const SearchScreen(),
    const LibraryScreen(),
  ];

  // ── Shake-to-skip ─────────────────────────────────────────────────
  // Global accelerometer listener, active for the whole lifetime of
  // MainShell (i.e. whenever the app is in the foreground) — gated live
  // by AudioPrefs.shakeToSkipNotifier so toggling the Settings switch
  // takes effect immediately without needing to restart the listener.
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime _lastShakeAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Rolling gravity-removed magnitude threshold — tuned to require a
  // deliberate shake (not just walking/pocket jostle). ~2.7g of combined
  // delta across axes, similar to common shake-detector packages.
  static const double _shakeThreshold = 27.0; // m/s² combined delta
  static const Duration _shakeCooldown = Duration(milliseconds: 900);

  void _startShakeListener() {
    _accelSub?.cancel();
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((event) {
      if (!AudioPrefs.shakeToSkipNotifier.value) return;
      final magnitude = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      // Subtract ~9.8 (1g at rest) so we're measuring motion, not gravity.
      final delta = (magnitude - 9.8).abs();
      if (delta < _shakeThreshold) return;

      final now = DateTime.now();
      if (now.difference(_lastShakeAt) < _shakeCooldown) return;
      _lastShakeAt = now;

      if (!mounted) return;
      final player = context.read<PlayerProvider>();
      if (!player.hasSong) return;
      HapticFeedback.mediumImpact();
      player.skipNext();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startShakeListener();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Update check
      final prefs = await SharedPreferences.getInstance();
      final checkUpdates = prefs.getBool('check_updates') ?? true;
      if (checkUpdates && mounted) {
        await UpdateService.checkForUpdate(context);
      }

      // THE crash-safe home for storage + battery-optimization permission
      // requests. Previously these were fired from main() before Flutter's
      // first frame had even been drawn — permission_handler's platform
      // channel needs a fully attached/resumed Activity, and calling it
      // that early was the likely source of the crash-on-launch some
      // devices hit. Here, we're safely past the splash animation, inside
      // the widget tree, on the very first frame of the real UI — the
      // same timing UpdateService.checkForUpdate above already uses
      // without issue.
      //
      // Gated by a one-time SharedPreferences flag so returning users
      // aren't nagged with the same dialogs on every launch — only once,
      // ever, per install (re-requesting a permanently-denied permission
      // silently no-ops anyway on Android, so this flag is purely to avoid
      // re-showing dialogs for permissions the user already answered).
      final askedPermissions = prefs.getBool('asked_launch_permissions') ?? false;
      if (!askedPermissions && mounted) {
        await _requestLaunchPermissions();
        await prefs.setBool('asked_launch_permissions', true);
      }

      // Keep Queue restore disabled — app opens clean, nothing shows until
      // the user explicitly plays a song.
      // await _restoreQueueIfNeeded();
    });
  }

  /// Storage/audio access (so Downloads and the Offline library work
  /// without a jarring mid-scan permission popup later) and battery
  /// optimization exemption (THE fix for aggressive OEM skins —
  /// Realme/ColorOS, MIUI, etc. — killing background playback within
  /// minutes regardless of everything else being correctly wired). Each
  /// request is independently try/caught: a denial of one never blocks or
  /// crashes the rest of the app, it just degrades that specific feature.
  Future<void> _requestLaunchPermissions() async {
    try {
      final audio = await Permission.audio.request();
      if (!audio.isGranted) await Permission.storage.request();
    } catch (_) {}

    if (!mounted) return;
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}

    // OEM autostart/background-allow dialog (realme/OPPO/MIUI/Vivo/etc).
    // Battery-optimization exemption alone isn't enough on these skins —
    // there's a separate "Auto-launch"/"Allow background running" toggle
    // that also has to be turned on manually, or the OS kills playback
    // within minutes regardless of the exemption above.
    if (!mounted) return;
    await _showAutostartDialog();
  }

  Future<void> _showAutostartDialog() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.darkBgCard,
        title: const Text('Keep music playing'),
        content: const Text(
          'Allow background running & auto-launch for Aurum so songs '
          "don't stop when the screen locks.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              LocalMusicService.openAutostartSettings();
            },
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accelSub?.cancel();
    super.dispose();
  }

  // Save queue when app goes to background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveQueue();
    }
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final keepQueue = prefs.getBool('keep_queue') ?? true;
    if (!keepQueue) return;

    final player = context.read<PlayerProvider>();
    if (player.queue.isEmpty) return;

    try {
      final queueJson =
          jsonEncode(player.queue.map((s) => s.toJson()).toList());
      await prefs.setString('saved_queue', queueJson);
      await prefs.setInt('saved_queue_index', player.currentIndex);
    } catch (_) {}
  }

  Future<void> _restoreQueueIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final keepQueue = prefs.getBool('keep_queue') ?? true;
    if (!keepQueue) return;

    final queueJson = prefs.getString('saved_queue');
    if (queueJson == null || queueJson.isEmpty) return;

    try {
      final List<dynamic> decoded = jsonDecode(queueJson);
      final songs = decoded
          .whereType<Map<String, dynamic>>()
          .map(Song.fromJson)
          .toList();
      if (songs.isEmpty) return;

      final index = (prefs.getInt('saved_queue_index') ?? 0)
          .clamp(0, songs.length - 1);

      if (!mounted) return;
      await context.read<PlayerProvider>().restoreQueueSilently(songs, index);
    } catch (_) {
      // Corrupt saved queue — clear it
      await prefs.remove('saved_queue');
      await prefs.remove('saved_queue_index');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: IndexedStack(index: _tab, children: _screens),
      // FIX — PERMANENT fix for "mini player disappears into a stuck pill
      // after theme/settings changes, only recoverable with an app
      // restart": this used to read a static `MiniPlayer.visibleNotifier`
      // that MiniPlayer's own widget lifecycle (initState/dispose) had to
      // keep in sync with reality. A theme change rebuilding MaterialApp
      // (see Consumer<ThemeProvider> in main.dart) could tear down and
      // recreate MiniPlayer's State independently of whether a song was
      // still genuinely playing, and dispose() forcing that notifier false
      // could leave it stuck — nothing was guaranteed to ever correct it
      // except a fresh app launch.
      //
      // Visibility now comes directly from PlayerProvider.miniPlayerVisible
      // (see its doc comment in player_provider.dart) via Selector.
      // PlayerProvider is created once, above MaterialApp, in the
      // MultiProvider in main.dart — it is never disposed or recreated by
      // a theme change, a settings screen, or any navigation. There is no
      // separate widget-lifecycle-bound copy of this state left anywhere
      // in the app to fall out of sync, which is what makes this bug class
      // structurally impossible now rather than just guarded against.
      bottomNavigationBar: Selector<PlayerProvider, bool>(
        selector: (_, p) => p.miniPlayerVisible,
        builder: (context, showingMiniPlayer, _) {
          // RepaintBoundary: floating SnackBars (settings confirmations,
          // "Added to playlist", etc.) are anchored to this Scaffold via
          // ScaffoldMessenger and can trigger a relayout pass around
          // bottomNavigationBar. Isolating this subtree's paint keeps
          // that pass from ever visually touching the mini player/nav
          // bar.
          return RepaintBoundary(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Background color scoped to just the mini player itself —
                // previously this color wrapped the mini player AND the nav
                // bar together in one Container, so whenever the mini
                // player was showing, the whole bottom section (mini
                // player + nav bar) painted as one solid flat block. That's
                // what read as a stray "pill"/panel sitting behind the
                // mini player's actual spot instead of just being its own
                // card. Now only the mini player's own area gets the card
                // color; the nav bar underneath keeps its own background.
                Container(
                  color: showingMiniPlayer
                      ? AurumTheme.bgCardOf(context)
                      : Colors.transparent,
                  child: const MiniPlayer(),
                ),
                // The nav bar no longer paints any top divider/gradient line
                // (removed permanently in _AurumBottomNavBar — see the
                // comment there). Just render it plainly; no style/song
                // state can affect it anymore, so no listener is needed here.
                _AurumBottomNavBar(
                  currentIndex: _tab,
                  onTap: (i) {
                    primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
                    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
                    setState(() => _tab = i);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// AURUM BOTTOM NAV BAR v2 — premium floating-pill tab bar.
//
// WHY THIS REWRITE:
//   The previous version had NO indicator behind the active tab at
//   all (a prior pill was removed per an earlier request, leaving
//   flat icon+label pairs with only a colour change). That reads as
//   a generic default tab bar, not a "top-level paid app" one.
//
//   This version brings back a floating pill — but built correctly
//   this time: a single AnimationController drives its horizontal
//   position with a spring curve (not a linear slide), so it
//   overshoots slightly and settles, the way a native iOS/well-built
//   Android tab indicator moves. The pill sits behind the icon+label
//   as a soft gold-tinted glass capsule, animates width text width so
//   it hugs the selected label naturally, and the icon does a small
//   scale-pop + haptic on selection so every tap feels tactile.
//
//   Structure: a Stack with the pill positioned via AnimatedPositioned
//   (spring curve) UNDER a plain Row of tap targets — exactly the
//   architecture the old code deliberately avoided ("no
//   Stack/LayoutBuilder needed"), reintroduced here because a moving
//   indicator is precisely what that structure is for.
// ══════════════════════════════════════════════════════════════════
class _AurumBottomNavBar extends StatelessWidget {
  const _AurumBottomNavBar({
    required this.currentIndex,
    required this.onTap,
  });
  final int currentIndex;
  final ValueChanged<int> onTap;

  static const _items = [
    (outline: PhosphorIconsRegular.houseSimple, filled: PhosphorIconsFill.houseSimple, label: 'Home'),
    (outline: PhosphorIconsRegular.magnifyingGlass, filled: PhosphorIconsFill.magnifyingGlass, label: 'Search'),
    (outline: PhosphorIconsRegular.vinylRecord, filled: PhosphorIconsFill.vinylRecord, label: 'Library'),
  ];

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    // REDESIGN v3 — roughly-half-height bar (46 vs the original 64) with
    // a top-to-bottom fade: the top ~40% is fully transparent so home
    // content shows through crisp (no blur — blur reads as "hiding
    // something", not deliberate). Only the portion right behind the
    // icons/labels fades to solid, for legibility. Height is 46, not a
    // stricter half (32), because pill+icon+label content genuinely
    // needs ~31px vertical room — going tighter starts clipping text or
    // forcing illegibly small font sizes, which reads as broken, not
    // premium.
    const barHeight = 46.0;
    return RepaintBoundary(
      child: SafeArea(
        top: false,
        child: Container(
          height: barHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.4, 1.0],
              colors: [
                Colors.transparent,
                AurumTheme.bgCardOf(context).withOpacity(isLight ? 0.55 : 0.5),
                AurumTheme.bgCardOf(context).withOpacity(isLight ? 0.97 : 0.99),
              ],
            ),
          ),
          child: Row(
            children: List.generate(_items.length, (i) {
              final item = _items[i];
              final selected = i == currentIndex;
              return Expanded(
                child: _NavTapScale(
                  selected: selected,
                  onTap: () {
                    if (!selected) HapticFeedback.selectionClick();
                    onTap(i);
                  },
                  child: SizedBox.expand(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Soft pill behind icon only, selected tab ──
                        // Reference screenshot: the tint sits tight
                        // around just the icon glyph, not the label
                        // or the full tab segment — a small rounded
                        // capsule, not a bright/hard-edged button.
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          width: 42,
                          height: 20,
                          decoration: BoxDecoration(
                            // Soft, not hard — low opacity tonal wash,
                            // matching the pale lavender capsule in
                            // the reference rather than a saturated
                            // fill.
                            color: selected
                                ? AurumTheme.gold.withOpacity(isLight ? 0.14 : 0.16)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(
                                begin: 1.0, end: selected ? 1.06 : 1.0),
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            builder: (context, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              transitionBuilder: (child, anim) =>
                                  ScaleTransition(
                                scale: anim,
                                child:
                                    FadeTransition(opacity: anim, child: child),
                              ),
                              child: Icon(
                                selected ? item.filled : item.outline,
                                key: ValueKey(selected),
                                size: 16,
                                color: selected
                                    ? AurumTheme.gold
                                    : AurumTheme.textMutedOf(context),
                              ),
                            ),
                          ),
                        ),
                        // Halved bar height leaves little room, but text
                        // below ~9.5px starts reading as illegible/cheap
                        // on real device DPI rather than "compact" — this
                        // is the smallest size that still stays crisp.
                        Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 9.5,
                            letterSpacing: 0.2,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                            color: selected
                                ? AurumTheme.gold
                                : AurumTheme.textMutedOf(context).withOpacity(0.85),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}


// ══════════════════════════════════════════════════════════════════
// NAV TAP SCALE v2 — press-down/spring-back scale PLUS a stronger
// haptic + a quick downward "settle" easing on release, so tapping a
// tab feels like pressing a real physical key, not a flat instant tap.
// The selected tab also gets a tiny continuous "breathing" isn't
// added (would be distracting) — instead all liveliness is
// concentrated into the moment of the tap itself.
// ══════════════════════════════════════════════════════════════════
class _NavTapScale extends StatefulWidget {
  const _NavTapScale({
    required this.onTap,
    required this.child,
    this.selected = false,
  });
  final VoidCallback onTap;
  final Widget child;
  final bool selected;

  @override
  State<_NavTapScale> createState() => _NavTapScaleState();
}

class _NavTapScaleState extends State<_NavTapScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: const Duration(milliseconds: 180),
    lowerBound: 0.0,
    upperBound: 1.0,
  );
  // A restrained 0.94 press-scale with smooth easeOutCubic both ways —
  // no elastic/spring overshoot on release. The press itself (going
  // down slightly on tapDown) is what reads as tactile; a bounce on
  // the way back up is the part that reads as playful/toy-like rather
  // than a quiet, deliberate control.
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.94).animate(
    CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) => Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}
