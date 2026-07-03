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

  final _screens = const [
    HomeScreen(),
    SearchScreen(),
    LibraryScreen(),
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
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          body: IndexedStack(index: _tab, children: _screens),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MiniPlayer(),
              // The nav bar's own top divider is meant for the edge-to-edge
              // "Compact Bar" mini player style. With the floating "Capsule"
              // style (rounded card, side margins) that divider is a straight
              // full-width line sitting just past the capsule's rounded
              // bottom corners — it reads as a stray white line under the
              // mini player instead of a bar separator. Suppress it whenever
              // a song is showing and the capsule style is active.
              ValueListenableBuilder<bool>(
                valueListenable: MiniPlayer.heroVisibleNotifier,
                builder: (context, heroVisible, _) {
                  return ValueListenableBuilder<String>(
                    valueListenable: MiniPlayer.styleNotifier,
                    builder: (context, miniPlayerStyle, _) {
                      // Divider must hide both when there's no song AND when
                      // the mini player is collapsed by the home hero scroll —
                      // otherwise the capsule's border survives as a stray
                      // white line after the mini player itself fades out.
                      final hideDivider = (player.hasSong && miniPlayerStyle != 'Compact Bar')
                          || heroVisible;
                      return _AurumBottomNavBar(
                        showTopDivider: !hideDivider,
                        currentIndex: _tab,
                        onTap: (i) {
                          primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
                          SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
                          setState(() => _tab = i);
                        },
                      );
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// AURUM BOTTOM NAV BAR — branded replacement for the stock Material
// BottomNavigationBar. A sliding gold-gradient glow pill sits behind
// the active tab, icons/labels smoothly cross-fade weight + color, and
// a haptic tick fires on switch — matches the premium search bar /
// tab bar / pull-to-refresh polish already used elsewhere in the app,
// instead of looking like a stock Flutter default.
// ══════════════════════════════════════════════════════════════════
class _AurumBottomNavBar extends StatelessWidget {
  const _AurumBottomNavBar({
    required this.currentIndex,
    required this.onTap,
    this.showTopDivider = true,
  });
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool showTopDivider;

  static const _items = [
    (outline: PhosphorIconsRegular.houseSimple, filled: PhosphorIconsFill.houseSimple, label: 'Home'),
    (outline: PhosphorIconsRegular.magnifyingGlass, filled: PhosphorIconsFill.magnifyingGlass, label: 'Search'),
    (outline: PhosphorIconsRegular.vinylRecord, filled: PhosphorIconsFill.vinylRecord, label: 'Library'),
  ];

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    // RepaintBoundary isolates this blur onto its own layer — the mini
    // player directly above uses its own BackdropFilter too, and letting
    // two backdrop filters share a compositing layer can make Android's
    // Skia backend blur the wrong region (same issue already fixed once
    // in mini_player.dart).
    return RepaintBoundary(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context).withOpacity(isLight ? 0.38 : 0.32),
              gradient: showTopDivider
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.04],
                      colors: [
                        Colors.white.withOpacity(isLight ? 0.28 : 0.10),
                        Colors.transparent,
                      ],
                    )
                  : null,
            ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final tabWidth = constraints.maxWidth / _items.length;
                  return Stack(
                    children: [
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        left: tabWidth * currentIndex + tabWidth * 0.14,
                        top: 8,
                        width: tabWidth * 0.72,
                        height: 48,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    AurumTheme.gold.withOpacity(isLight ? 0.16 : 0.20),
                                    AurumTheme.gold.withOpacity(isLight ? 0.06 : 0.08),
                                  ],
                                ),
                                border: Border.all(
                                  color: AurumTheme.gold.withOpacity(isLight ? 0.28 : 0.32),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AurumTheme.gold.withOpacity(0.18),
                                    blurRadius: 18,
                                    spreadRadius: -2,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: List.generate(_items.length, (i) {
                          final item = _items[i];
                          final selected = i == currentIndex;
                          return Expanded(
                            child: _NavTapScale(
                              onTap: () {
                                if (!selected) HapticFeedback.selectionClick();
                                onTap(i);
                              },
                              child: SizedBox.expand(
                                child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    transitionBuilder: (child, anim) => ScaleTransition(
                                      scale: anim,
                                      child: FadeTransition(opacity: anim, child: child),
                                    ),
                                    child: Icon(
                                      selected ? item.filled : item.outline,
                                      key: ValueKey(selected),
                                      size: 24,
                                      color: selected
                                          ? AurumTheme.gold
                                          : AurumTheme.textMutedOf(context),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  AnimatedDefaultTextStyle(
                                    duration: const Duration(milliseconds: 220),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                                      color: selected
                                          ? AurumTheme.gold
                                          : AurumTheme.textMutedOf(context),
                                    ),
                                    child: Text(item.label),
                                  ),
                                ],
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// NAV TAP SCALE — wraps each nav item with a quick press-down/spring-
// back scale so tapping a tab feels tactile, like a native paid-app
// button, instead of a flat instant tap with no physical feedback.
// ══════════════════════════════════════════════════════════════════
class _NavTapScale extends StatefulWidget {
  const _NavTapScale({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_NavTapScale> createState() => _NavTapScaleState();
}

class _NavTapScaleState extends State<_NavTapScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 180),
    lowerBound: 0.0,
    upperBound: 1.0,
  );
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.88).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeOut, reverseCurve: Curves.elasticOut),
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
