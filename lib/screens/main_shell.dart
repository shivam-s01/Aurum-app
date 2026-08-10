import 'dart:async';
import '../utils/aurum_transitions.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../widgets/feedback_dialog.dart';
import '../services/feedback_service.dart';
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
import '../shorts/screens/shorts_entry.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _tab = 0;

  final _homeKey = GlobalKey<State<HomeScreen>>();

  // NOTE: Shorts is intentionally NOT in this list. It is a full-screen
  // immersive feed pushed via Navigator (see _handleNavTap) rather than
  // an IndexedStack tab, so it never inherits the persistent MiniPlayer/
  // nav bar chrome or interferes with the main queue's IndexedStack
  // state. _screens stays 3 items; _tab only ever indexes 0..2 here.
  // NOTE: SearchScreen needs isActive rebuilt on every _tab change, so it
  // can't be `late final` like before — it's rebuilt as a getter that
  // reflects the current _tab so the search keyboard focus logic knows
  // exactly when the Search tab is really visible (see search_screen.dart).
  List<Widget> get _screens => [
    HomeScreen(key: _homeKey, isActive: _tab == 0),
    SearchScreen(isActive: _tab == 1),
    const LibraryScreen(),
  ];

  // Maps _AurumBottomNavBar's 4-item display index (Home, Search,
  // Shorts, Library) to this screen's 3-item _screens/_tab index.
  // Shorts (bar index 2) has no _screens entry, so it's excluded from
  // this mapping and handled separately in _handleNavTap.
  static const Map<int, int> _barIndexToTab = {0: 0, 1: 1, 3: 2};

  void _handleNavTap(int barIndex) {
    primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

    if (barIndex == _AurumBottomNavBar.shortsTabIndex) {
      AurumHaptics.selection();
      Navigator.of(context).push(
        AurumPageRoute(
          builder: (_) => const ShortsEntry(),
          fullscreenDialog: true,
        ),
      );
      return;
    }

    final tab = _barIndexToTab[barIndex];
    if (tab != null) setState(() => _tab = tab);
  }

  // Reverse mapping so the nav bar highlights the correct icon for
  // the currently active _screens tab (Shorts has no persistent
  // highlight since it's not a resident tab).
  int get _activeBarIndex =>
      _barIndexToTab.entries.firstWhere((e) => e.value == _tab).key;

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
    _accelSub = null;
    // PERF FIX (battery/CPU): this used to always subscribe to the
    // accelerometer stream at gameInterval (~50Hz) for the app's entire
    // foreground lifetime, regardless of whether Shake to Skip was even
    // turned on — the callback checked the setting and bailed out, but
    // only *after* the stream had already woken the CPU, delivered the
    // event across the platform channel, and run the sqrt/magnitude
    // math. On a 2GB device that's a continuous, pointless background
    // cost for a feature most people never enable.
    // Now: don't subscribe at all unless the setting is actually on, and
    // react live to it being toggled (see the listener added in
    // initState) instead of subscribing unconditionally up front.
    if (!AudioPrefs.shakeToSkipNotifier.value) return;
    _accelSub = accelerometerEventStream(
      // uiInterval (~60ms/~16Hz) is still plenty fast to catch a
      // deliberate shake gesture — a shake unfolds over a few hundred ms,
      // not a single frame — while roughly a third of gameInterval's
      // wake-up/compute frequency. Cuts this listener's own CPU cost
      // further for the (now much rarer) case where it's actually active.
      samplingPeriod: SensorInterval.uiInterval,
    ).listen((event) {
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
      AurumHaptics.medium();
      player.skipNext();
    });
  }

  // ── Feedback auto-prompt ──────────────────────────────────────────
  // Listens for song changes on PlayerProvider and asks FeedbackService
  // whether it's time to show the "rate us" dialog (after 1-2 songs,
  // then quiet for 12h — see feedback_service.dart for the exact rule).
  String? _lastTrackedSongId;
  VoidCallback? _feedbackListener;
  // FIX (rare crash on teardown): dispose() used to call
  // context.read<PlayerProvider>() to remove this listener. Reading an
  // InheritedWidget via context after this widget is already mid-dispose
  // (e.g. the whole app tree unmounting on force-close) can throw
  // "Looking up a deactivated widget's ancestor is unsafe". Storing the
  // provider reference directly here means dispose() never needs to
  // touch context at all.
  PlayerProvider? _trackedPlayer;

  void _startFeedbackTracking() {
    final player = context.read<PlayerProvider>();
    _trackedPlayer = player;
    _feedbackListener = () {
      final song = player.currentSong;
      if (song == null || song.id == _lastTrackedSongId) return;
      _lastTrackedSongId = song.id;
      FeedbackService.onSongPlayed().then((shouldPrompt) {
        if (shouldPrompt && mounted) {
          // FIX ("full player swipe-down se close karte hi ek gray/dark
          // layer reh jaata hai, tap se nahi jaata"): this listener fires
          // on ANY song change, on ANY screen — including while
          // FullPlayerScreen is open or mid-swipe-to-dismiss. showDialog's
          // own barrier (barrierDismissible: false, see
          // feedback_dialog.dart) doesn't know or care that
          // FullPlayerScreen's swipe-to-dismiss is a live drag gesture in
          // progress — it just pushes a DialogRoute on top of whatever's
          // current the instant a song change lands, which could be the
          // exact same frame the user is dragging the full player off-
          // screen. The dialog's own barrier then paints over/behind that
          // drag, and because it's non-dismissible by tap or swipe, it's
          // the layer that's left showing once the drag/pop settles.
          // Checking canPop() on the root navigator here means the dialog
          // simply waits until the user is back on a base screen (nothing
          // pushed on top of MainShell) before ever appearing — it can
          // never land mid-transition or mid-gesture again.
          final rootNavigator = Navigator.of(context, rootNavigator: true);
          if (rootNavigator.canPop()) return;
          showFeedbackDialog(context);
        }
      });
    };
    player.addListener(_feedbackListener!);
  }

  // FIX: PlayerProvider.playbackError was set whenever a song genuinely
  // failed to play (native call hung/threw — see playSong()'s try/catch),
  // with a doc comment saying "screens can watch this to show a retry
  // snackbar/toast" — but nothing anywhere in the app actually read it.
  // A failed song silently went from "loading" to nothing, with no
  // explanation and no way to retry short of tapping the song again and
  // hoping. Wiring it here means it's shown regardless of which screen
  // the user is on when playback fails, exactly like the feedback
  // listener above.
  VoidCallback? _playbackErrorListener;

  void _startPlaybackErrorTracking() {
    final player = _trackedPlayer ?? context.read<PlayerProvider>();
    _playbackErrorListener = () {
      final err = player.playbackError;
      if (err == null || !mounted) return;
      final failedSong = player.lastFailedSong;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(err),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          action: failedSong == null
              ? null
              : SnackBarAction(
                  label: 'RETRY',
                  onPressed: () => player.playSong(failedSong),
                ),
        ));
      // One-shot: clear it immediately after showing, so backgrounding/
      // resuming the app or a provider rebuild can't re-show the same
      // stale error a second time.
      player.clearPlaybackError();
    };
    player.addListener(_playbackErrorListener!);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startShakeListener();
    // Live-react to the setting: if the user turns Shake to Skip on/off
    // from Settings while the app is open, start/stop the sensor stream
    // immediately rather than waiting for MainShell to rebuild.
    AudioPrefs.shakeToSkipNotifier.addListener(_startShakeListener);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _startFeedbackTracking();
      _startPlaybackErrorTracking();

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
      // requests. permission_handler's platform channel needs a fully
      // attached/resumed Activity — calling it too early was the likely
      // source of a crash-on-launch some devices hit.
      //
      // PERF FIX (2026-08 — "app takes ~30s after splash before it feels
      // smooth"): this used to add an extra hardcoded 2700ms
      // Future.delayed here, on top of the splash's own 2.7s animation,
      // under the assumption that MainShell mounted from frame 1
      // (alongside the splash) and therefore needed its own separate
      // wait before the Activity was safely resumed enough for
      // permission_handler. That assumption is stale: SplashScreen
      // (see its SEQUENCING comment) now only builds/mounts widget.child
      // — i.e. this MainShell — AFTER its own animation has already
      // fully completed. By the time this initState even runs, the
      // splash is long gone and the Activity has been resumed and
      // interactive for a full frame already. The extra 2700ms here was
      // pure dead time stacked on top of the splash's own 2.7s, reading
      // to the user as "smooth for a moment, then ~30s more of stutter"
      // while update-check/permissions/sync all sat idle waiting on a
      // timer that no longer protected against anything.
      if (!mounted) return;

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
    AudioPrefs.shakeToSkipNotifier.removeListener(_startShakeListener);
    _accelSub?.cancel();
    if (_feedbackListener != null) {
      _trackedPlayer?.removeListener(_feedbackListener!);
    }
    if (_playbackErrorListener != null) {
      _trackedPlayer?.removeListener(_playbackErrorListener!);
    }
    super.dispose();
  }

  // Tracks whether the app was actually backgrounded, so `resumed` only
  // triggers a sync on a genuine return to the app.
  //
  // FIX (keyboard opens then instantly closes, app-wide): opening the
  // keyboard can make Android briefly cycle the Activity's focus (some
  // OEM IMEs/keyboards do this), which Flutter reports as a transition
  // through `inactive` and straight back to `resumed` — without ever
  // actually pausing. That "resumed" used to unconditionally call
  // _handleForegroundSync(), which reads four providers and syncs them;
  // if that sync (or the provider notifies it triggers) caused a rebuild
  // while a dialog was open — feedback, create playlist, rename playlist,
  // any TextField anywhere — the field's focus got stolen a moment after
  // being tapped, reading as the keyboard flashing open then slamming
  // shut. Per-dialog FocusNode fixes couldn't catch this because the
  // interruption wasn't coming from the dialog's own transition at all.
  // Now `resumed` only runs the sync if we've actually observed `paused`
  // (a real backgrounding) since the last sync — a keyboard-driven blip
  // that never truly pauses the app no longer fires it.
  bool _wasPaused = false;

  // Save queue when app goes to background; pull the latest cloud state
  // when it comes back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _wasPaused = true;
      _saveQueue();
    } else if (state == AppLifecycleState.resumed) {
      if (_wasPaused) {
        _wasPaused = false;
        _handleForegroundSync();
      }
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
      // extendBody: true — lets page content (HomeScreen/SearchScreen/
      // LibraryScreen) scroll underneath the floating nav bar/mini player
      // instead of stopping short and leaving a solid-colored gap behind
      // them. Combined with the frosted-glass capsule below, this is what
      // makes content visibly (blurred) through the bar, matching a
      // premium "paid app" look instead of an opaque white strip.
      extendBody: true,
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
                  currentIndex: _activeBarIndex,
                  onTap: _handleNavTap,
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

  // index 2 ("Shorts") is a special case: tapping it does NOT switch
  // the IndexedStack — it pushes the full-screen Shorts feed as its
  // own route (see onTap handling in MainShell). It stays out of
  // _tab's normal 0..2 range so the capsule highlight never rests on
  // it after returning.
  static List<({dynamic outline, dynamic filled, String label})> _items(AppLocalizations l10n) => [
    (outline: PhosphorIconsRegular.houseSimple, filled: PhosphorIconsFill.houseSimple, label: l10n.navHome),
    (outline: PhosphorIconsRegular.magnifyingGlass, filled: PhosphorIconsFill.magnifyingGlass, label: l10n.navSearch),
    (outline: PhosphorIconsRegular.playCircle, filled: PhosphorIconsFill.playCircle, label: l10n.navShorts),
    (outline: PhosphorIconsRegular.vinylRecord, filled: PhosphorIconsFill.vinylRecord, label: l10n.navLibrary),
  ];

  static const int shortsTabIndex = 2;

  static const double _barHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = _items(l10n);
    final accent = context.select<ThemeProvider, Color>((tp) => tp.accentColor);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Floating frosted-glass capsule: side margins so it doesn't touch
    // the screen edges, ClipRRect + BackdropFilter for the blur, and a
    // translucent tinted fill on top so page content underneath (visible
    // thanks to Scaffold's extendBody: true) reads as a soft blurred
    // smear rather than a flat opaque bar — the "paid app" look.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          // PERF/HEAT SETTING: nav bar sits on screen on every tab, so its
          // BackdropFilter blur runs every single frame it's visible — a
          // real, continuous GPU cost that shows up as device heat on
          // weaker hardware during long sessions. Wrapping just this shell
          // in a ValueListenableBuilder (not the whole nav bar) means only
          // the blur/decoration re-renders when the user changes the
          // setting in Settings → Appearance — the tab icons/labels Stack
          // below is completely unaffected. sigma == 0 skips BackdropFilter
          // entirely (cheapest possible option: flat tinted bar, same look
          // FullPlayerScreen's own route-transition fallback already uses).
          child: ValueListenableBuilder<double>(
            valueListenable: AudioPrefs.navBarBlurSigmaNotifier,
            builder: (context, blurSigma, navBarContent) {
              // blurSigma <= 0 means the user explicitly turned blur OFF
              // (Settings → Appearance → "Nav Bar Blur" dragged to 0).
              // That should read as a fully solid, opaque bar — not a
              // translucent "glass without the blur" look — so nothing
              // behind it shows through at all. Only the blurred variant
              // keeps the semi-transparent tint that lets BackdropFilter's
              // blur actually be visible underneath.
              final bar = Container(
                height: _barHeight,
                decoration: BoxDecoration(
                  color: blurSigma <= 0
                      ? AurumTheme.bgCardOf(context)
                      : (isDark ? Colors.black : Colors.white)
                          .withValues(alpha: isDark ? 0.45 : 0.65),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: (isDark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.08),
                    width: 1,
                  ),
                ),
                child: navBarContent,
              );
              if (blurSigma <= 0) return bar;
              return BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: bar,
              );
            },
            child: LayoutBuilder(
                builder: (context, constraints) {
                  final tabWidth = constraints.maxWidth / items.length;
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
                  children: List.generate(items.length, (i) {
                    final item = items[i];
                    final selected = i == currentIndex;
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (!selected) AurumHaptics.selection();
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
                                  // FIX: was ValueKey(selected) — every tab's
                                  // icon shares just two possible keys
                                  // (true/false), so switching from one
                                  // selected tab to a different tab could
                                  // reuse the previous tab's Element instead
                                  // of treating it as a genuinely new icon,
                                  // which skipped or glitched the fade
                                  // transition. Keying on the tab index too
                                  // makes every icon's identity unique.
                                  key: ValueKey('$i-$selected'),
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
        ),
      ),
    );
  }
}
