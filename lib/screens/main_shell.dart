import 'dart:async';
import 'dart:convert';
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
import '../providers/theme_provider.dart';
import '../services/update_service.dart';
import '../services/local_music_service.dart';
import '../services/audio_prefs.dart';
import '../services/sync_service.dart';
import '../providers/auth_provider.dart';
import '../providers/premium_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/favorites_provider.dart';

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
      // Cold-launch sync: didChangeAppLifecycleState's resumed branch
      // only fires on a paused→resumed transition, which a fresh app
      // launch never passes through (it starts straight in "resumed").
      // Without this, a user already signed in on two devices who just
      // opens the app fresh — rather than backgrounding and returning to
      // it — would see stale library state until the next
      // background/foreground cycle. Placed here (post-frame) rather
      // than directly in initState so every provider's own init() (Hive
      // box opens, etc.) has had a chance to complete first — reading
      // PlaylistProvider.playlists etc. before that finishes would just
      // see an empty list and skip pushing anything local-only up.
      // Fire-and-forget, same as the resume-path sync.
      _handleForegroundSync();

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

  // Save queue when app goes to background; pull the latest cloud state
  // when it comes back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveQueue();
    } else if (state == AppLifecycleState.resumed) {
      _handleForegroundSync();
    }
  }

  // Runs a full pull-then-push sync any time the app returns to the
  // foreground, so a playlist/favorite/follow added on another device
  // while this device was backgrounded shows up here without the user
  // having to sign out and back in. syncAll() itself already no-ops
  // instantly if nobody's signed in or a sync is already in flight, and
  // this is fire-and-forget (no await at the call site in
  // didChangeAppLifecycleState) so resuming the app is never blocked on
  // a network round trip.
  Future<void> _handleForegroundSync() async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isSignedIn) return;
    final premium = context.read<PremiumProvider>();
    if (!premium.isPremium) return;
    try {
      await SyncService.instance.syncAll(
        playlists: context.read<PlaylistProvider>(),
        followedArtists: context.read<FollowedArtistsProvider>(),
        followedAlbums: context.read<FollowedAlbumsProvider>(),
        favorites: context.read<FavoritesProvider>(),
      );
    } catch (_) {
      // Best-effort — a failed foreground sync just means we try again
      // on the next resume or the next explicit sign-in; nothing here
      // should ever surface an error to the user for a background op.
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
        builder: (context, _, __) {
          // RepaintBoundary: floating SnackBars (settings confirmations,
          // "Added to playlist", etc.) are anchored to this Scaffold via
          // ScaffoldMessenger and can trigger a relayout pass around
          // bottomNavigationBar. Isolating this subtree's paint keeps
          // that pass from ever visually touching the mini player/nav
          // bar.
          // FIX — the actual source of the "ghost pill": Scaffold's
          // `bottomNavigationBar` slot is ALWAYS wrapped internally by
          // Flutter in its own Material widget, which paints a solid
          // fill color there by default — regardless of whether our own
          // MiniPlayer/_AurumBottomNavBar widgets have any background of
          // their own. That implicit fill is what kept showing through
          // as a stray pill/panel behind the mini player, even after
          // every Container/decoration in mini_player.dart and
          // main_shell.dart was already fully transparent. Wrapping our
          // actual content in an explicit transparent Material here
          // makes that implicit fill paint nothing, so only our own
          // widgets' pixels are ever visible.
          return Material(
            color: Colors.transparent,
            elevation: 0,
            surfaceTintColor: Colors.transparent,
            child: RepaintBoundary(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // FIX — removed the card-color background that used to wrap
                // just the mini player's own area. That solid fill was the
                // "ghost pill" showing up behind the mini player content —
                // now this Container paints nothing; the mini player renders
                // with a fully transparent background behind it.
                const MiniPlayer(),
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
            ),
          );
        },
      ),
    );
  }
}


// ══════════════════════════════════════════════════════════════════
// AURUM BOTTOM NAV BAR — Echo Nighty style.
//
// Ported directly from Echo Nighty's bottom nav: NO bar container at
// all — no background fill, no blur, no shadow, no top border/divider.
// Icons and labels float straight on top of page content. The only
// visual element is a solid filled rounded-rect capsule that sits
// behind the active tab's icon+label pair and slides between tabs.
//
// This replaces the old glass/blur/shadow "v2" pill bar. Constructor
// signature (currentIndex, onTap) is unchanged, so MainShell's build()
// above needs no edits.
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

  static const double _barHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    final accent = context.select<ThemeProvider, Color>((tp) => tp.accentColor);

    // No RepaintBoundary/DecoratedBox/BackdropFilter/Container wrapper —
    // deliberately nothing here to paint as a "bar". SafeArea handles
    // the bottom system inset, everything else is just the tap row.
    return SafeArea(
      top: false,
      child: SizedBox(
        height: _barHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabWidth = constraints.maxWidth / _items.length;
            return Stack(
              alignment: Alignment.center,
              children: [
                // ── Active tab capsule ──────────────────────────────
                // Solid filled rounded-rect behind the selected tab's
                // icon+label column, matching Echo's flat filled pill
                // (no border, no shadow, no glass) — just tinted with
                // Aurum's gold/bronze accent instead of Echo's lavender.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic,
                  left: tabWidth * currentIndex,
                  top: 6,
                  bottom: 6,
                  width: tabWidth,
                  child: Center(
                    child: Container(
                      width: tabWidth - 24,
                      height: _barHeight - 12,
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.20),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
                // ── Tap targets ──────────────────────────────────────
                Row(
                  children: List.generate(_items.length, (i) {
                    final item = _items[i];
                    final selected = i == currentIndex;
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (!selected) HapticFeedback.selectionClick();
                          onTap(i);
                        },
                        child: SizedBox.expand(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeOutCubic,
                                transitionBuilder: (child, anim) => FadeTransition(
                                  opacity: anim,
                                  child: child,
                                ),
                                child: Icon(
                                  selected ? item.filled : item.outline,
                                  key: ValueKey(selected),
                                  size: 24,
                                  color: selected
                                      ? accent
                                      : AurumTheme.textMutedOf(context),
                                ),
                              ),
                              const SizedBox(height: 4),
                              AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 180),
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.0,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: selected
                                      ? accent
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
    );
  }
}
