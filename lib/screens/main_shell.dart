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
import 'package:sensors_plus/sensors_plus.dart';
import '../theme/aurum_theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/aurum_glass.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_play_pause_icon.dart';
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
import '../providers/recently_played_provider.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _tab = 0;

  final _homeKey = GlobalKey<State<HomeScreen>>();

  // _screens stays 3 items; _tab only ever indexes 0..2 here.
  // NOTE: SearchScreen needs isActive rebuilt on every _tab change, so it
  // can't be `late final` like before — it's rebuilt as a getter that
  // reflects the current _tab so the search keyboard focus logic knows
  // exactly when the Search tab is really visible (see search_screen.dart).
  List<Widget> get _screens => [
    HomeScreen(key: _homeKey, isActive: _tab == 0),
    SearchScreen(isActive: _tab == 1),
    const LibraryScreen(),
  ];

  // Maps AurumBottomNavBar's display index directly to this screen's
  // _screens/_tab index — Home/Search/Library, 1:1, no special cases.
  static const Map<int, int> _barIndexToTab = {0: 0, 1: 1, 2: 2};

  void _handleNavTap(int barIndex) {
    primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

    final tab = _barIndexToTab[barIndex];
    if (tab != null) setState(() => _tab = tab);
  }

  // Reverse mapping so the nav bar highlights the correct icon for
  // the currently active _screens tab.
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

      // FIX ("purane users ko update popup nahi mil raha"): 'check_updates'
      // is disk-persisted and never had any UI to toggle it — it could
      // only ever have been set to false manually/temporarily (e.g. while
      // testing around build 646). Because it's a plain persisted bool,
      // any install that ever passed through that state keeps
      // check_updates=false forever on every future launch/build, with no
      // way for the user to know or fix it themselves. This is a one-time,
      // one-way migration: if the stale `false` is found, it's cleared
      // back to the default (true) exactly once and never touched again,
      // so it doesn't fight a real "Check for Update" toggle if one gets
      // added to Settings later.
      const migrationFlag = 'check_updates_regression_fix_applied_v1';
      if (prefs.getBool('check_updates') == false &&
          !(prefs.getBool(migrationFlag) ?? false)) {
        await prefs.remove('check_updates');
        await prefs.setBool(migrationFlag, true);
      }

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

    // Battery-optimization-ignore system popup removed on request — never
    // show it, at launch or anywhere else.
    if (!mounted) return;

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
        backgroundColor: AurumTheme.bgCardOf(ctx),
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
    // Cloud sync is sign-in-gated now, not payment-gated — every signed-in
    // user gets it, same as every other feature. isPremium is ads-only.
    if (!auth.isSignedIn) return;
    try {
      await SyncService.instance.syncAll(
        playlists: context.read<PlaylistProvider>(),
        followedArtists: context.read<FollowedArtistsProvider>(),
        followedAlbums: context.read<FollowedAlbumsProvider>(),
        favorites: context.read<FavoritesProvider>(),
        history: context.read<RecentlyPlayedProvider>(),
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
    // BACK-BUTTON FIX (Spotify/YT Music parity): MainShell is the root
    // route, so with no PopScope, back on Search/Library exited the app.
    // Back now walks exactly ONE level per press:
    //   Library inner step (multi-select / sub-tab)  ->  Library overview
    //   any non-Home tab                              ->  Home
    //   Home                                          ->  exit app
    // Pushed routes (album/artist/playlist/full player...) sit on top of
    // MainShell, so Navigator pops those first and never reaches this.
    // canPop only depends on _tab: on Library the shell always intercepts
    // (canPop=false), and Library's own inner step is resolved at the moment
    // of the back press via LibraryBackScope.handleBack() — no need to
    // rebuild the shell every time Library's inner state changes.
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _tab == 0) return;
        // Library first: undo its own inner step (select mode / sub-tab)
        // before ever leaving the Library tab.
        if (_tab == 2 && LibraryBackScope.handleBack()) return;
        primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        setState(() => _tab = 0);
      },
      child: Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // FIX (root cause of "keyboard khulte hi search bar/header/pura tab
      // host upar tak khisak/squeeze ho jaata hai", found while rechecking
      // search_screen.dart's own keyboard-padding fix): this OUTER
      // Scaffold — the one actually holding the bottomNavigationBar
      // (nav bar + mini player) and the IndexedStack of all three tabs —
      // was left at Flutter's default resizeToAvoidBottomInset (true).
      // SearchScreen's OWN inner Scaffold already sets this to false, but
      // that only stops that inner Scaffold from resizing a SECOND time —
      // it does nothing about this outer one. Because SearchScreen's
      // TextField lives inside THIS Scaffold's body (via the IndexedStack),
      // it was still this outer Scaffold that shrank its `body` to avoid
      // the keyboard, squeezing the entire tab host — header and search
      // bar included — from the bottom every time the keyboard opened.
      // Setting it to false here means neither Scaffold ever resizes for
      // the keyboard; SearchScreen's own explicit
      // `viewInsets.bottom` padding on just its results list (see
      // search_screen.dart) is what actually reserves the right amount of
      // space now, with header/search bar/background staying completely
      // fixed regardless of keyboard state — nothing shifts or resizes
      // anywhere in the tab host.
      resizeToAvoidBottomInset: false,
      // extendBody: true — lets page content (HomeScreen/SearchScreen/
      // LibraryScreen) scroll underneath the floating nav bar/mini player
      // instead of stopping short and leaving a solid-colored gap behind
      // them. Combined with the frosted-glass capsule below, this is what
      // makes content visibly (blurred) through the bar, matching a
      // premium "paid app" look instead of an opaque white strip.
      extendBody: true,
      // FIX (Library/Home/Search content shifting up/down when the mini
      // player shows or hides): Scaffold recomputes MediaQuery.viewPadding
      // .bottom to match bottomNavigationBar's live height, and it does
      // this on every frame of the mini player's AnimatedSize show/hide
      // animation (see bottomNavigationBar below). Each screen's own
      // SafeArea(bottom: false) only stops that value being consumed as
      // padding at its own top level — it does nothing to stop that
      // same live-changing MediaQuery from reaching further down into a
      // screen's own CustomScrollView/ListView, which is exactly what
      // was making Library's "Recently Played" rail (and everything
      // below the Most Played hero card) visibly slide during the mini
      // player's fade/resize instead of staying put like Spotify/YT
      // Music, where content position never depends on whether a mini
      // player happens to be showing right now. MediaQuery.removePadding
      // here pins bottom padding to 0 for the entire IndexedStack
      // subtree, permanently and independent of bottomNavigationBar's
      // height — each screen already reserves its own fixed bottom
      // space via a constant SliverPadding (see e.g. library_screen.dart's
      // `EdgeInsets.fromLTRB(20, 0, 20, 110)`), so nothing is lost behind
      // the nav bar/mini player; that reserved space just stops being
      // re-derived from a value that changes underneath it.
      body: MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: IndexedStack(index: _tab, children: _screens),
      ),
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
      //
      // FIX (Spotify-parity — "nav bar disappears when the mini player is
      // dismissed"): the nav bar used to live *inside* the same
      // Selector<..., miniPlayerVisible> as MiniPlayer, so dismissing the
      // mini player (swipe-to-close, or nothing playing yet) took the nav
      // bar down with it — Home/Search/Library became unreachable.
      // Real Spotify/YT Music never do this: the nav bar is permanent
      // chrome, fully independent of whether anything is currently
      // playing; only the mini player itself shows/hides on its own.
      // Splitting them into two siblings here — Selector wraps only
      // MiniPlayer now, AurumBottomNavBar sits outside it — makes the nav
      // bar unconditional again while keeping the mini player's own
      // show/hide behavior exactly as before.
      bottomNavigationBar: Material(
        color: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        // NO RepaintBoundary here on purpose (removed for real glass):
        // a BackdropFilter can only sample the layer it lives in. A
        // RepaintBoundary above the nav bar / mini player puts them in
        // their own compositing layer, so the glass shader receives an
        // EMPTY backdrop and renders as a flat tinted panel instead of
        // refracting the page content behind it. The snackbar-relayout
        // isolation it used to provide is not worth losing real glass.
        child: _GlassBackdropPassthrough(
          // FIX — the actual source of the "ghost pill": Scaffold's
          // `bottomNavigationBar` slot is ALWAYS wrapped internally by
          // Flutter in its own Material widget, which paints a solid
          // fill color there by default — regardless of whether our own
          // MiniPlayer/AurumBottomNavBar widgets have any background of
          // their own. That implicit fill is what kept showing through
          // as a stray pill/panel behind the mini player, even after
          // every Container/decoration in mini_player.dart and
          // main_shell.dart was already fully transparent. Wrapping our
          // actual content in an explicit transparent Material here
          // makes that implicit fill paint nothing, so only our own
          // widgets' pixels are ever visible.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // FIX — removed the card-color background that used to wrap
              // just the mini player's own area. That solid fill was the
              // "ghost pill" showing up behind the mini player content —
              // now this Container paints nothing; the mini player renders
              // with a fully transparent background behind it.
              //
              // Only this Selector controls the mini player's own
              // visibility now — dismissing it (or nothing playing yet)
              // no longer takes the nav bar down too (see FIX above).
              //
              // FIX ("song play karte hi mini player aane par screen
              // khichti hai, stable feel nahi deta" — same root cause
              // MiniPlayerSlot.dart already diagnosed and fixed for
              // pushed screens, see that file's matching comment for
              // the full mechanism): the AnimatedSize+AnimatedSwitcher
              // pair below used to run as two independent animations —
              // AnimatedSize interpolating this Column's HEIGHT while a
              // separate AnimatedSwitcher cross-faded the mini player's
              // widget identity — both racing to settle on their own
              // ticker. Height and opacity finishing even a few ms apart
              // reads as a visible pop/jerk (the layout resizing while
              // the content is still only partially faded in), and on a
              // root tab like Library — sitting directly above a
              // CustomScrollView — that height change also nudges the
              // scroll viewport's own extent, which is exactly the
              // "screen khichti hai" pull. Switched to the same fix
              // already proven in MiniPlayerSlot: ONE AnimatedSwitcher
              // with a Stack layoutBuilder (bottom-aligned, no shared
              // height interpolation) drives fade+slide+scale together
              // from a single Tween, and MiniPlayer's own height is
              // simply present or absent — never animated as a
              // continuous size change that could tug at page content
              // above it.
              Selector<PlayerProvider, bool>(
                selector: (_, p) => p.miniPlayerVisible,
                builder: (context, visible, __) => AnimatedSwitcher(
                  duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                  switchInCurve: AurumMotion.standard,
                  switchOutCurve: AurumMotion.standardReverse,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  ),
                  // NO FadeTransition: Opacity/fade < 1 forces a saveLayer that
                  // cuts the glass BackdropFilter off from the page behind it, so
                  // the glass flashes flat during show/hide. Slide+scale only.
                  transitionBuilder: (child, anim) => GlassSafeEnter(
                    anim: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.12),
                        end: Offset.zero,
                      ).animate(anim),
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.97, end: 1.0).animate(anim),
                        alignment: Alignment.bottomCenter,
                        child: child,
                      ),
                    ),
                  ),
                  child: visible
                      ? const MiniPlayer(key: ValueKey('mini_player_visible'))
                      : const SizedBox.shrink(key: ValueKey('mini_player_hidden')),
                ),
              ),
              // The nav bar no longer paints any top divider/gradient line
              // (removed permanently in AurumBottomNavBar — see the
              // comment there). Always rendered, independent of the mini
              // player's visibility — see the FIX comment above.
              AurumBottomNavBar(
                currentIndex: _activeBarIndex,
                onTap: _handleNavTap,
              ),
            ],
          ),
        ),
      ),
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
// ── Tap "pump" scale for nav tabs (Play Store / SimpMusic style) ──────────
// Wraps a tab's icon+label column so tapping it plays a quick scale-down-
// then-spring-back-up bounce, instead of just being a flat, instant tab
// switch. GestureDetector (not InkWell) so no ripple/splash competes with
// the scale — the bounce itself IS the tap feedback here, same as Play
// Store's bottom nav. onTapDown starts the shrink immediately (feels
// instant, no wait for onTap/pointer-up) and onTapUp/onTapCancel spring it
// back with an overshoot curve for that "pump" feel rather than a plain
// linear return.
class _NavTabTapPump extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _NavTabTapPump({required this.child, required this.onTap});

  @override
  State<_NavTabTapPump> createState() => _NavTabTapPumpState();
}

class _NavTabTapPumpState extends State<_NavTabTapPump>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AurumMotion.durationOrZero(AurumMotion.short1),
    reverseDuration: AurumMotion.durationOrZero(AurumMotion.medium2),
  );
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.86).animate(
    CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOut,
      // Overshoot curve on the way back up is what gives the "pump" feel
      // (icon springs slightly past 1.0 before settling) instead of a flat
      // ease-back — same spring character Play Store's own nav bounce has.
      reverseCurve: Curves.elasticOut,
    ),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) => _ctrl.forward();
  void _up(TapUpDetails _) => _ctrl.reverse();
  void _cancel() => _ctrl.reverse();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _cancel,
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}

class AurumBottomNavBar extends StatelessWidget {
  const AurumBottomNavBar({
    required this.currentIndex,
    required this.onTap,
  });
  final int currentIndex;
  final ValueChanged<int> onTap;

  // SimpMusic uses plain Material Symbols for its bottom nav (Home /
  // Search / Library) — swapped from Phosphor to Flutter's built-in
  // Icons here to match that exact look. `uses-material-design: true`
  // is already set in pubspec.yaml, so no new package/asset needed.
  // Material has no filled "library_music" variant, so outline is
  // reused there for both states — same as SimpMusic's own bar, where
  // the library icon doesn't swap shape on selection either.
  static List<({dynamic outline, dynamic filled, String label})> _items(AppLocalizations l10n) => [
    (outline: Icons.home_outlined, filled: Icons.home, label: l10n.navHome),
    (outline: Icons.search, filled: Icons.search, label: l10n.navSearch),
    (outline: Icons.library_music_outlined, filled: Icons.library_music_outlined, label: l10n.navLibrary),
  ];

  static const double _barHeight = 64.0;
  // Exposed so MiniPlayerSlot (pushed content screens) can reserve the
  // exact same footprint the nav bar occupies here, even though it never
  // renders the bar itself — see MiniPlayerSlot's doc comment for why
  // that matters.
  static const double barHeight = _barHeight;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = _items(l10n);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // FIX ("nav bar + search collapse ekdam SimpMusic jaisa hona chahiye,
    // glass ON rahe tab"): two structural changes from the previous
    // Docked-only version, both driven purely by existing toggles/state —
    // no new Settings entries added.
    //
    // 1) Shape now follows the Liquid Glass toggle directly instead of
    //    being hardcoded to Docked: glass ON → floating rounded capsule
    //    (side margins, full rounded corners, real refracting glass —
    //    matches SimpMusic's own floating glass nav bar exactly). Glass
    //    OFF → the previous Docked edge-to-edge/square-corner look,
    //    completely unchanged.
    // 2) When the Search tab (index 1) is the active tab, the whole
    //    3-tab row collapses down to just a single round floating search
    //    button — matching SimpMusic's own search-screen nav bar exactly
    //    — and expands back to the full 3-tab row the instant another
    //    tab becomes active. Purely presentational: currentIndex/onTap
    //    wiring below is completely unchanged, so tapping the collapsed
    //    search button still calls onTap(1) same as before.
    return ValueListenableBuilder<bool>(
      valueListenable: AudioPrefs.liquidGlassEnabledNotifier,
      builder: (context, glassOn, __) {
        final docked = !glassOn;
        // Docked: identical full 3-tab bar on every tab (no collapse).
        // Glass ON: Search tab collapses to the lone round glass button.
        final searchActive = currentIndex == 1 && !docked;
        return SafeArea(
          top: false,
          // Bottom safe-area padding is always respected regardless of
          // shape — see original FIX comment: this never changes tap
          // reliability on gesture-nav devices either way below.
          child: Padding(
            padding: docked
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: AnimatedSwitcher(
              duration: AurumMotion.durationOrZero(AurumMotion.medium2),
              switchInCurve: AurumMotion.standard,
              switchOutCurve: AurumMotion.standardReverse,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(anim),
                  alignment: Alignment.bottomCenter,
                  child: child,
                ),
              ),
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              ),
              // Keyed on (searchActive, docked) — either changing plays
              // the collapse/expand or shape-swap animation smoothly
              // instead of an instant cut.
              child: searchActive
                  ? _CollapsedSearchButton(
                      key: const ValueKey('nav_collapsed_search'),
                      docked: docked,
                      isDark: isDark,
                      onTap: () => onTap(1),
                    )
                  : _FullNavRow(
                      key: ValueKey('nav_full_$docked'),
                      docked: docked,
                      isDark: isDark,
                      items: items,
                      currentIndex: currentIndex,
                      onTap: onTap,
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// The normal 3-tab Home/Search/Library row, in either Docked
/// (edge-to-edge, square, unchanged from before) or Floating (rounded
/// capsule with real glass, active whenever Liquid Glass is ON) shape.
class _FullNavRow extends StatelessWidget {
  final bool docked;
  final bool isDark;
  final List<({dynamic outline, dynamic filled, String label})> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  const _FullNavRow({
    super.key,
    required this.docked,
    required this.isDark,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Docked is always edge-to-edge/square-corner, so this outer
    // ClipRRect uses a zero radius either way — a plain rectangle
    // clip, which doesn't cut off AurumGlass's own contact shadow
    // the way a rounded outer clip would (that's why Floating used
    // to skip the clip's radius instead of matching it).
    return ClipRRect(
      clipBehavior: Clip.none,
      borderRadius: docked
          ? BorderRadius.zero
          : BorderRadius.circular(28),
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
      child: ValueListenableBuilder<bool>(
        valueListenable: AudioPrefs.liquidGlassEnabledNotifier,
        builder: (context, glassOn, navBarContent) {
          final blurSigma = glassOn ? AudioPrefs.glassNavSigma : 0.0;
          // PERF/BATTERY FIX (zero-tolerance heating/battery request):
          // same fix as mini_player.dart's effectiveBlurSigma — this
          // nav bar sits underneath every pushed screen too (MainShell
          // never leaves the tree), and opaque:false route transitions
          // keep it actively compositing/blurring behind whatever is
          // pushed on top. Gate on ModalRoute.of(context)?.isCurrent
          // exactly the same way: not the top route → treat as
          // sigma 0 (solid, no BackdropFilter), so the blur's
          // continuous GPU/heat cost only ever runs while the nav bar
          // itself is actually the thing on screen.
          final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;
          final effectiveBlurSigma = isTopRoute ? blurSigma : 0.0;
          if (docked && glassOn) {
            return SizedBox(
              height: AurumBottomNavBar._barHeight,
              child: AurumGlass(
                sigma: effectiveBlurSigma,
                borderRadius: BorderRadius.zero,
                isDark: isDark,
                tintColor: AurumTheme.bgCardOf(context),
                useTintInGlass: false,
                child: navBarContent!,
              ),
            );
          }
          if (docked) {
            return SizedBox(
              height: AurumBottomNavBar._barHeight,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.0),
                              Colors.black.withValues(alpha: isDark ? 0.28 : 0.10),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  navBarContent!,
                ],
              ),
            );
          }
          // Floating (glass ON, not docked): real refracting glass
          // capsule — matches SimpMusic's own floating glass nav bar.
          return SizedBox(
            height: AurumBottomNavBar._barHeight,
            child: AurumGlass(
              sigma: effectiveBlurSigma,
              borderRadius: BorderRadius.circular(28),
              isDark: isDark,
              tintColor: AurumTheme.bgCardOf(context),
              useTintInGlass: false,
              child: navBarContent!,
            ),
          );
        },
        child: LayoutBuilder(
            builder: (context, constraints) {
              // SimpMusic-exact indicator: the selected tab's icon and
              // label sit side-by-side in a Row, wrapped in a soft grey
              // pill sized to that content (not a fixed guessed size) —
              // so the pill always hugs exactly what's inside it.
              // Unselected tabs stay icon-over-label with no pill at
              // all, matching the reference screenshots exactly. Each
              // tab gets an equal-width slot so tap targets stay large
              // and consistent regardless of which tab is selected.
              final slotWidth = constraints.maxWidth / items.length;
              return Row(
                children: List.generate(items.length, (i) {
                  final item = items[i];
                  final selected = i == currentIndex;
                  return SizedBox(
                    width: slotWidth,
                    height: AurumBottomNavBar._barHeight,
                    child: _NavTabTapPump(
                      onTap: () {
                        if (!selected) AurumHaptics.selection();
                        onTap(i);
                      },
                      child: Center(
                        child: AnimatedContainer(
                        duration: AurumMotion.durationOrZero(AurumMotion.medium2),
                        curve: AurumMotion.standard,
                        padding: selected
                            ? const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8)
                            : const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: selected
                              ? (isDark ? Colors.white : Colors.black)
                                  .withValues(alpha: isDark ? 0.14 : 0.08)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: selected
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    item.filled,
                                    size: 22,
                                    color: AurumTheme.textPrimaryOf(context),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    item.label,
                                    style: TextStyle(
                                      fontFamily: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.fontFamily,
                                      fontSize: 13,
                                      height: 1.0,
                                      fontWeight: FontWeight.w600,
                                      color: AurumTheme.textPrimaryOf(context),
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    item.outline,
                                    size: 24,
                                    color: AurumTheme.textMutedOf(context),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.label,
                                    style: TextStyle(
                                      fontFamily: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.fontFamily,
                                      fontSize: 11,
                                      height: 1.0,
                                      fontWeight: FontWeight.w500,
                                      color: AurumTheme.textMutedOf(context),
                                    ),
                                  ),
                                ],
                              ),
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
        ),
      ),
    );
  }
}

/// Collapsed single round floating search button — replaces the full
/// 3-tab row whenever the Search tab is active, matching SimpMusic's own
/// search-screen nav bar exactly (a lone round glass button, bottom-left,
/// everything else given back to the page). Tapping it just calls back
/// into the same onTap(1) the full row's Search tab already used, so the
/// tab-switching logic in MainShell needs zero changes.
class _CollapsedSearchButton extends StatelessWidget {
  final bool docked;
  final bool isDark;
  final VoidCallback onTap;
  const _CollapsedSearchButton({
    super.key,
    required this.docked,
    required this.isDark,
    required this.onTap,
  });

  static const double _size = 56.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Same left/bottom breathing room either shape uses for its own
      // edge inset, so the row sits in a consistent spot whether Docked
      // or Floating is active underneath it.
      padding: EdgeInsets.only(
        left: docked ? 12 : 0,
        right: docked ? 12 : 0,
        bottom: docked ? 8 : 0,
      ),
      // FIX (recheck — CRASH): this Row holds an Expanded child (the
      // compact mini player chip) below. Row defaults its cross axis
      // fine, but MainAxisSize.min here is invalid together with a
      // flexible (Expanded/Flexible) child — Flutter throws
      // "RenderFlex children have non-zero flex but incoming width
      // constraints are unbounded" the instant a song plays and this
      // row's Expanded actually tries to claim space, because .min
      // tells Row to size itself to content while Expanded simultaneously
      // demands to fill available space — a direct contradiction. This
      // never surfaced while the row only ever held the plain search
      // button (no flexible child existed yet), which is exactly why
      // adding the mini player chip here is what exposed it. Row's
      // default (MainAxisSize.max) is correct and required whenever an
      // Expanded/Flexible child is present — removed the override.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // FIX ("search ke bagal mai mini player dalna hai, SimpMusic
          // jaisa"): SimpMusic's Search screen keeps the mini player
          // sitting beside the collapsed round search button instead of
          // hiding it — a compact chip here, not the full-width
          // MiniPlayer widget (which assumes the whole row's width for
          // its drag-to-dismiss gesture and text layout; cramming that
          // into half a row would break both). Hidden entirely when
          // nothing is playing, exactly like the full MiniPlayer already
          // does on every other tab.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _CompactMiniPlayerChip(docked: docked, isDark: isDark),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: AudioPrefs.liquidGlassEnabledNotifier,
            builder: (context, glassOn, button) {
              final blurSigma = glassOn ? AudioPrefs.glassNavSigma : 0.0;
              final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;
              final effectiveBlurSigma = isTopRoute ? blurSigma : 0.0;
              return SizedBox(
                width: _size,
                height: _size,
                child: AurumGlass(
                  sigma: effectiveBlurSigma,
                  borderRadius: BorderRadius.circular(_size / 2),
                  isDark: isDark,
                  tintColor: AurumTheme.bgCardOf(context),
                  useTintInGlass: false,
                  interactive: true,
                  child: button!,
                ),
              );
            },
            child: _NavTabTapPump(
              onTap: onTap,
              child: Icon(
                Icons.search,
                size: 24,
                color: AurumTheme.textPrimaryOf(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small artwork + title + play/pause chip shown beside the collapsed
/// search button on the Search tab, matching SimpMusic's own layout.
/// Deliberately its own tiny widget rather than reusing the full-width
/// [MiniPlayer] — that widget's swipe-to-dismiss drag math and text
/// layout both assume the full row width, and it already lives in its
/// own AnimatedSwitcher slot right above this nav bar (still driving the
/// real Now Playing state) — this chip is purely a compact, read-only
/// mirror of it for the one tab where the nav row is otherwise mostly
/// empty space. Tapping it opens the same Full Player as everywhere else.
class _CompactMiniPlayerChip extends StatelessWidget {
  final bool docked;
  final bool isDark;
  const _CompactMiniPlayerChip({required this.docked, required this.isDark});

  static const double _height = 52.0;

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, Song?>(
      selector: (_, p) => p.miniPlayerVisible ? p.currentSong : null,
      builder: (context, song, __) {
        if (song == null) return const SizedBox.shrink();
        return SizedBox(
          height: _height,
          child: ValueListenableBuilder<bool>(
            valueListenable: AudioPrefs.liquidGlassEnabledNotifier,
            builder: (context, glassOn, content) {
              final blurSigma = glassOn ? AudioPrefs.glassNavSigma : 0.0;
              final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;
              final effectiveBlurSigma = isTopRoute ? blurSigma : 0.0;
              return AurumGlass(
                sigma: effectiveBlurSigma,
                borderRadius: BorderRadius.circular(_height / 2),
                isDark: isDark,
                tintColor: AurumTheme.bgCardOf(context),
                useTintInGlass: false,
                interactive: true,
                // FIX (build error: "Widget?' can't be assigned to
                // 'Widget'"): ValueListenableBuilder's builder passes its
                // static `child` back as Widget? (nullable), even though
                // it's always non-null here since one is always provided
                // below. The other AurumGlass callers in this same file
                // (_FullNavRow, _CollapsedSearchButton's own search
                // button) already unwrap this identically with `button!`
                // — this one just used the wrong bare variable name.
                child: content!,
              );
            },
            child: AurumPressable(
              scaleAmount: 0.97,
              haptic: false,
              onTap: () => pushFullPlayer(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                // FIX (recheck): was `mainAxisSize: MainAxisSize.min`.
                // This chip sits inside an Expanded (in the row above),
                // which DOES hand this Row a tight/definite width — but
                // MainAxisSize.min tells Row to still size itself to its
                // CONTENT's width rather than fill that available space,
                // which starves the Flexible(Text) below of any width to
                // actually shrink within. On a long song title this meant
                // the ellipsis logic never truly kicked in at the size
                // that matters, and on some widths the play button could
                // sit flush against — or clip past — the glass pill's
                // rounded edge instead of staying inset. Removing
                // mainAxisSize (Row defaults to MainAxisSize.max) makes
                // this Row actually fill the Expanded width it's given,
                // so Flexible gets a real, definite width to shrink text
                // into and the trailing play button always stays fully
                // inside the pill with its intended padding.
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(_height / 2 - 4),
                      child: AurumArtwork(
                        url: song.artworkUrl,
                        size: _height - 8,
                        borderRadius: _height / 2 - 4,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AurumTheme.textPrimaryOf(context),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Selector<PlayerProvider, ({bool isLoading, bool isPlaying})>(
                      selector: (_, p) =>
                          (isLoading: p.isLoading, isPlaying: p.isPlaying),
                      builder: (context, state, _) {
                        if (state.isLoading) {
                          return const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        return AurumPressable(
                          scaleAmount: 0.85,
                          haptic: false,
                          onTap: () {
                            AurumHaptics.heavy();
                            context.read<PlayerProvider>().togglePlay();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: AurumPlayPauseIcon(
                              isPlaying: state.isPlaying,
                              color: AurumTheme.textPrimaryOf(context),
                              size: 20,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Identity wrapper. Exists only so the bottomNavigationBar subtree keeps
/// the exact same nesting depth it had when a RepaintBoundary lived here.
/// It adds NO layer, clip, or boundary — a BackdropFilter below must see
/// the page content, and any RepaintBoundary/ClipRect/Opacity above it
/// would give the glass shader an empty backdrop.
class _GlassBackdropPassthrough extends StatelessWidget {
  final Widget child;
  const _GlassBackdropPassthrough({required this.child});
  @override
  Widget build(BuildContext context) => child;
}
