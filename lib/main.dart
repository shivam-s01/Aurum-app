import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/native_engine_bridge.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/audio_prefs.dart';
import 'services/sync_service.dart';
import 'providers/player_provider.dart';
import 'providers/library_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/locale_provider.dart';
import 'l10n/generated/app_localizations.dart';
import 'providers/download_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/followed_artists_provider.dart';
import 'providers/followed_albums_provider.dart';
import 'providers/saved_mixes_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/premium_provider.dart';
import 'theme/aurum_theme.dart';
import 'screens/main_shell.dart';
import 'screens/library_screen.dart';
import 'providers/source_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/recently_played_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/app_lock_screen.dart';
import 'utils/aurum_transitions.dart';

late NativeAudioEngine _audioEngine;

/// Global navigator key — lets the notification-tap callback (which fires
/// outside the widget tree) push the Downloads screen.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Global ScaffoldMessenger key — lets debug tooling (e.g. the keyboard
// flash watchdog) and any other code without a reliable local Scaffold
// ancestor (bottom sheets, dialogs) show a SnackBar reliably. Without
// this, ScaffoldMessenger.of(context) inside a sheet/dialog context can
// silently find no messenger and do nothing — which looks exactly like
// "the bug doesn't happen" even when it still does.
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Global RouteObserver — lets FullPlayerScreen pause ambient animations
/// whenever a route is pushed on top (lyrics, queue, options sheets).
final RouteObserver<ModalRoute<void>> aurumRouteObserver =
    RouteObserver<ModalRoute<void>>();

Future<void> main() async {
  runZonedGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();

  // THE fix for "background playback/notification unreliable on Android
  // 13+": AndroidManifest.xml already declares POST_NOTIFICATIONS, but
  // declaring a dangerous permission in the manifest does not grant it —
  // Android 13+ (API 33+) requires an explicit runtime request, exactly
  // like camera or location. Without this being granted, the system can
  // suppress AurumMediaSessionService's foreground notification entirely,
  // which in turn makes Android treat the service as a low-priority
  // "invisible" background process and kill it far more aggressively.
  // Requested here (pre-UI) because it's a lightweight, well-behaved
  // permission_handler call with no known crash history.
  //
  // Storage/audio and battery-optimization permissions are intentionally
  // NOT requested here anymore — they're requested from MainShell's first
  // frame instead (see main_shell.dart), fully inside the widget tree
  // after the splash animation and Flutter UI are actually up. Firing
  // multiple permission_handler system dialogs this early, before
  // Flutter's first frame has even been drawn, was the likely source of
  // the crash-on-launch some devices hit — permission_handler's platform
  // channel can be fragile if invoked before the Activity is fully
  // attached/resumed.
  // PERF FIX (the actual "app freezes for a second on open" cause): this
  // request used to be `await`-ed HERE, before runApp() — which meant
  // Flutter's very first frame couldn't even be painted until the user
  // dismissed the system permission dialog. On a device where that
  // dialog takes a moment to appear (or the user pauses before tapping),
  // the entire screen just sits blank/black, which reads exactly like
  // "the app is lagging/frozen on launch" even though nothing was
  // actually slow — Flutter was simply never given the chance to draw
  // anything yet.
  // The permission itself doesn't need to be granted before any UI can
  // show — it only affects whether the background playback notification
  // is visible later. Fired fire-and-forget after runApp() (see bottom
  // of this function) instead, so the splash/home UI paints immediately
  // and the system dialog appears as a normal overlay on top of a
  // already-visible, already-interactive app, the way permission
  // prompts work in virtually every other Android app.

  // Wake the Saavn free-tier backend the instant the app launches — by the
  // time the user reaches Home/Search it's had a head start to warm up.
  ApiService.wakeSaavn();

  // Hive init for local DB (favorites, playlists, recently played, downloads)
  await Hive.initFlutter();

  // Apply user's image cache size preference to Flutter's in-memory image
  // cache. This is separate from cached_network_image's disk cache, but
  // controls how many decoded images are kept in RAM.
  //
  // PERF FIX: reads SharedPreferences.getInstance() a second time here —
  // AudioPrefs.load() below also opens it. SharedPreferences.getInstance()
  // is itself cached process-wide after the first call, so this was
  // already cheap, but reordered below to share one lookup and shave one
  // redundant plugin channel round-trip off the startup path.
  final prefs = await SharedPreferences.getInstance();
  try {
    final maxImgMB = prefs.getDouble('max_image_cache') ?? 100.0;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        (maxImgMB * 1024 * 1024).toInt();
    // PERF FIX (2GB-RAM smoothness): Flutter's default imageCache.maximumSize
    // (item count, separate from the byte-size cap above) is 1000 — on a
    // long scroll session (Library with hundreds of tracks, or Search
    // results) that's up to 1000 decoded image entries kept alive with
    // their own bookkeeping/GC overhead, even while comfortably under the
    // byte-size limit above. Artwork here is small and heavily downscaled
    // already (see AurumArtwork._cacheSize — capped to size*2, or 220px for
    // blurred backgrounds), so 250 entries is still generous headroom for
    // smooth scrolling — several screens worth of visible + prefetched
    // tiles — while meaningfully cutting the worst-case memory/GC pressure
    // on weaker devices.
    PaintingBinding.instance.imageCache.maximumSize = 250;
  } catch (_) {}

  // Supabase init — must happen before any AuthService/Supabase.instance use.
  // NOTE: this one genuinely can't move to the post-runApp() block below —
  // AuthProvider.init() (see main.dart's MultiProvider) runs synchronously
  // the moment runApp() builds the widget tree, and it immediately touches
  // Supabase.instance.client via AuthService.instance.authStateChanges.
  // Deferring Supabase.initialize() past runApp() would make that a crash
  // (accessing Supabase.instance before Supabase.initialize() has run)
  // instead of a perf win. In practice this call is fast (local client
  // setup, no network round-trip of its own), so it isn't the source of
  // the launch delay — the notification permission dialog below was.
  try {
    await AuthService.init();
  } catch (_) {} // app still works fully offline/unauthenticated if this fails

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Restore Player & Audio settings (shake-to-skip, swipe-to-change,
  // stop-on-swipe, pause-on-call, duck-on-notifications, etc.) from disk
  // BEFORE the audio engine/UI spin up. Without this, every AudioPrefs
  // static defaults to its hardcoded value on a genuine cold start —
  // toggles the user turned on would silently stop working until they
  // happened to open a Settings screen again (settings_notifications_screen
  // was the only other place calling this). try/catch so a prefs read
  // failure can never block app startup.
  try {
    await AudioPrefs.load();
  } catch (_) {}

  // NativeAudioEngine just wires up MethodChannel/EventChannel listeners —
  // it doesn't block on any platform-side MediaSession registration (unlike
  // the old AudioService.init(), which awaited the audio_service plugin's
  // async platform handshake). The actual MediaSession/notification is now
  // owned by AurumMediaSessionService (Kotlin), which MainActivity binds to
  // (bindService + startService in configureFlutterEngine) the moment the
  // Flutter engine attaches — see MainActivity.bindMediaSessionService().
  // Media3's own internal MediaNotificationManager then promotes the
  // service to foreground automatically once real playback starts. So
  // construction here is synchronous and can never hang or race a timeout
  // the way the old AudioService.init() call could.
  _audioEngine = NativeAudioEngine();

  // PERF FIX: NotificationService.instance.init() only sets up local
  // notification channels/plugin registration — nothing else in this
  // function depends on it having finished, and nothing visible on the
  // very first frame needs it either. Moved off the pre-runApp() blocking
  // path (fire-and-forget below, alongside AuthService.init() and the
  // notification permission request) so it can complete in the background
  // while the UI is already up and interactive instead of adding its own
  // few dozen ms to the blank-screen window before first paint.

  runApp(AurumApp(engine: _audioEngine));

  // ── Everything below runs AFTER the first frame is already up ──────────
  // None of this is needed to paint Home/Search/Library correctly, so it
  // no longer delays runApp() by a single millisecond. Each is still
  // independently try/caught so one failing can never affect another or
  // crash the (already-running) app.
  try {
    await Permission.notification.request();
  } catch (_) {}

  try {
    await NotificationService.instance.init();
    NotificationService.instance.onNotificationTapped = () {
      navigatorKey.currentState?.push(
        AurumPageRoute(builder: (_) => const DownloadsScreen()),
      );
    };
  } catch (_) {}
  }, (error, stack) {
    debugPrint('[Aurum] Uncaught error: $error\n$stack');
  });
}

class AurumApp extends StatelessWidget {
  final NativeAudioEngine engine;
  const AurumApp({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(
          create: (_) {
            final sp = SourceProvider();
            // Auto-switch is driven by real connectivity (see init()).
            // When it flips while a song is playing, the previous source's
            // playback (online stream URL or local file) is no longer
            // valid for the new mode — stop it immediately instead of
            // leaving a dead/wrong song stuck in the mini player.
            //
            // FIX: engine.stop() is async and was called fire-and-forget
            // with no error handling. If the player has nothing loaded
            // (e.g. user toggles source before playing anything) or the
            // native ExoPlayer call throws, that became an unhandled
            // Future rejection that crashed the app the instant the
            // Online/Offline pill was tapped. Now any failure is caught
            // and swallowed — stopping playback is best-effort, it should
            // never be able to take down the UI.
            sp.onSourceChanged = () {
              engine.stop().catchError((e, st) {
                debugPrint('[Aurum] stop() on source change failed: $e');
              });
            };
            sp.init();
            return sp;
          },
        ),
        ChangeNotifierProvider(create: (_) => RecentlyPlayedProvider()..init()),
        ChangeNotifierProvider(create: (_) => DownloadProvider(engine)..init()),
        ChangeNotifierProxyProvider<DownloadProvider, FavoritesProvider>(
          create: (_) => FavoritesProvider()..init(),
          update: (_, dl, fav) {
            fav?.downloadProvider = dl;
            return fav ?? (FavoritesProvider()..init()..downloadProvider = dl);
          },
        ),
        ChangeNotifierProvider(create: (_) => PlaylistProvider()..init()),
        ChangeNotifierProvider(create: (_) => FollowedArtistsProvider()..init()),
        ChangeNotifierProvider(create: (_) => FollowedAlbumsProvider()..init()),
        ChangeNotifierProvider(create: (_) => SavedMixesProvider()..init()),
        ChangeNotifierProvider(
          create: (_) {
            final auth = AuthProvider();
            auth.init();
            // Keep AudioPrefs in sync so service-layer code (PlayerProvider)
            // can check isSignedIn without a BuildContext — mirrors the
            // isPremium wiring just below for the same reason.
            AudioPrefs.isSignedIn = auth.isSignedIn;
            auth.addListener(() => AudioPrefs.isSignedIn = auth.isSignedIn);
            return auth;
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final pp = PremiumProvider();
            // Spotify-style cross-device check: _refresh() now calls
            // Supabase's getUser() (real network round-trip, not the
            // locally cached session) so a payment made on another
            // device shows up here without the user having to sign out
            // and back in. If that check is stuck long enough to look
            // broken rather than just "loading", let them know it's a
            // connectivity problem, not premium being lost/denied.
            pp.onSlowNetwork = () {
              scaffoldMessengerKey.currentState?.showSnackBar(
                const SnackBar(
                  content: Text('Please check your internet connection'),
                  duration: Duration(seconds: 3),
                ),
              );
            };
            pp.init();
            // Keep AudioPrefs in sync so service-layer (ApiService) can
            // check isPremium without a BuildContext.
            pp.addListener(() => AudioPrefs.isPremium = pp.isPremium);
            // Same reasoning, for SyncService: incremental cloud pushes
            // (see providers/playlist_provider.dart etc.) fire from deep
            // inside provider mutation methods with no BuildContext
            // available, so SyncService needs its own way to ask "is this
            // user currently premium" right before deciding to push.
            SyncService.instance.isPremium = () => pp.isPremium;
            return pp;
          },
        ),
        ChangeNotifierProxyProvider2<RecentlyPlayedProvider, FavoritesProvider, PlayerProvider>(
          create: (_) => PlayerProvider(engine),
          update: (_, recentlyPlayed, favorites, player) {
            final p = player ?? PlayerProvider(engine, recentlyPlayedProvider: recentlyPlayed);
            p.updateRecentlyPlayed(recentlyPlayed);
            p.updateFavorites(favorites);
            return p;
          },
        ),
      ],
      // DynamicColorBuilder harvests the system's wallpaper-derived
      // ColorScheme on Android 12+ (via the platform's dynamic color APIs)
      // and rebuilds whenever it changes — e.g. the user changes wallpaper
      // while Aurum is open, no app restart needed. On unsupported
      // platforms/OS versions both schemes come back null, which
      // ThemeProvider.isDynamicAvailable checks for before ever using them.
      child: DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          return Consumer2<ThemeProvider, LocaleProvider>(
            builder: (context, themeProvider, localeProvider, _) {
          // Push the latest schemes into ThemeProvider every build. This is
          // cheap (identical() short-circuits inside updateDynamicSchemes)
          // and is the only path through which "Dynamic Color" mode in
          // Settings > Appearance ever gets real colors to render with.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            themeProvider.updateDynamicSchemes(lightDynamic, darkDynamic);
          });

          final isDark = themeProvider.themeMode == ThemeMode.dark ||
              themeProvider.isAmoled ||
              (themeProvider.isDynamic && themeProvider.isDynamicAvailable &&
                  darkDynamic != null &&
                  WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                      Brightness.dark) ||
              (themeProvider.themeMode == ThemeMode.system &&
                  WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                      Brightness.dark);

          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            systemStatusBarContrastEnforced: false,
            // Transparent, not a solid fill — the nav bar is now a floating
            // glass capsule (see main_shell.dart's extendBody: true), with
            // real page content visible in the margins around/behind it.
            // A solid systemNavigationBarColor here painted a color strip
            // that didn't match that content, which flashed as a dark/black
            // edge during route push/pop slide transitions once the nav
            // bar stopped being an opaque full-width bar.
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarContrastEnforced: false,
          ));

          // Resolve font-aware ThemeData. Dynamic mode swaps in the
          // wallpaper-derived Material You scheme when one is actually
          // available (Android 12+); on any other platform/OS version it
          // silently behaves like the normal Dark theme instead of leaving
          // the user on a broken/blank theme.
          final baseLight = (themeProvider.isDynamic && lightDynamic != null)
              ? AurumTheme.dynamicTheme(lightDynamic)
              : AurumTheme.lightTheme;
          final baseDark = (themeProvider.isDynamic && darkDynamic != null)
              ? AurumTheme.dynamicTheme(darkDynamic)
              : (themeProvider.isAmoled
                  ? AurumTheme.amoledTheme
                  : AurumTheme.darkTheme);

          final lightTheme = baseLight.copyWith(
            textTheme: themeProvider.resolvedTextTheme(baseLight.textTheme),
          );
          final darkTheme = baseDark.copyWith(
            textTheme: themeProvider.resolvedTextTheme(baseDark.textTheme),
          );

          return MaterialApp(
            navigatorKey: navigatorKey,
            scaffoldMessengerKey: scaffoldMessengerKey,
            title: 'Aurum Music',
            debugShowCheckedModeBanner: false,
            themeMode: themeProvider.themeMode,
            theme: lightTheme,
            darkTheme: darkTheme,
            navigatorObservers: [aurumRouteObserver],
            locale: localeProvider.locale,
            supportedLocales: kSupportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            // If locale is null (user hasn't picked one — "follow system"),
            // Flutter tries to match the device's system locale against
            // supportedLocales. If the device is set to a language Aurum
            // doesn't ship translations for (e.g. German), this callback
            // falls back to English rather than Flutter's default behavior
            // of falling back to the first supportedLocales entry
            // regardless of fit — same practical result here since English
            // is first, but explicit so this doesn't silently break if the
            // list order ever changes.
            localeResolutionCallback: (deviceLocale, supported) {
              if (deviceLocale != null) {
                for (final l in supported) {
                  if (l.languageCode == deviceLocale.languageCode) return l;
                }
              }
              return const Locale('en');
            },
            // NOTE: _BlurShaderWarmup wraps here, OUTSIDE
            // _SplashOnEveryEntry's child — that child is only built by
            // SplashScreen once its own 2.7s animation finishes (see
            // _showChild in splash_screen.dart), so nesting the warmup
            // inside it would fire the warmup at the exact moment the
            // splash hands off to the real app, defeating the point.
            // Wrapping it out here instead means the warmup paints
            // immediately, hidden behind/alongside the splash itself.
            home: _BlurShaderWarmup(
              child: AppLockScreen(
                child: _SplashOnEveryEntry(child: const MainShell()),
              ),
            ),
            ); // closes MaterialApp
            }, // closes Consumer2 builder
          ); // closes Consumer2
        }, // closes DynamicColorBuilder builder
      ), // closes DynamicColorBuilder
    ); // closes MultiProvider
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// _SplashOnEveryEntry
// ─────────────────────────────────────────────────────────────────────────────
//
// Shows the Aurum intro animation ONLY on a true cold start (first process
// launch). Background-resume (Home button → reopen, recents → reopen) skips
// straight back to whatever the user was doing — no repeated animation.
//
// How: a static bool `_played` is set to true the first time the splash
// completes. It lives on the class (not in State) so it survives hot-reload
// and background/foreground cycles for the entire Dart VM lifetime. On
// Android, AurumMediaSessionService (the native Kotlin foreground service)
// keeps the process alive in the background while music plays, so the Dart
// VM is not restarted on a normal resume — `_played` stays true and the
// splash is skipped. Only a genuine force-close + relaunch resets the
// process and clears `_played`, giving a fresh cold-start animation.
// ─────────────────────────────────────────────────────────────────────────────
// _BlurShaderWarmup
// ─────────────────────────────────────────────────────────────────────────────
//
// FIX (full player "3 second stuck" on open): the full player's background
// (_StaticBlurArtwork in full_player_screen.dart) uses ImageFilter.blur at a
// large sigma. The very FIRST time any ImageFilter.blur is painted in a
// process's lifetime, Skia has to compile/warm that blur shader on the GPU —
// a one-time cost that can run into the hundreds of ms to a few seconds on
// mid-range Android GPUs. Because that first blur used to happen the moment
// the user opened the full player, it read as the player being stuck/frozen.
//
// Fix: paint one throwaway 1x1 blurred box, fully offstage and invisible,
// the moment the app's widget tree first builds (right under the splash,
// so it's hidden either way). This forces Skia to compile the shader once,
// harmlessly, before the user ever taps a song — so the real first open is
// instant.
class _BlurShaderWarmup extends StatefulWidget {
  final Widget child;
  const _BlurShaderWarmup({required this.child});

  @override
  State<_BlurShaderWarmup> createState() => _BlurShaderWarmupState();
}

class _BlurShaderWarmupState extends State<_BlurShaderWarmup> {
  // Survives hot-reload / background-resume for the process lifetime, same
  // pattern as _SplashOnEveryEntry._played — only a real cold start should
  // pay this cost again.
  static bool _warmed = false;

  @override
  Widget build(BuildContext context) {
    if (_warmed) return widget.child;
    _warmed = true;
    return Stack(
      children: [
        widget.child,
        // Offstage: laid out and painted once (which is all we need to
        // force shader compilation) but never actually shown or hit-tested.
        Positioned(
          left: -100,
          top: -100,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: Stack(
                children: [
                  // Blur shader (nav bar, mini player, dialogs, mix/profile
                  // screens all use BackdropFilter.blur at various sigmas —
                  // one compile covers every sigma; Skia caches by filter
                  // *type*, not by parameter).
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: const SizedBox(width: 4, height: 4),
                  ),
                  // PERF FIX (extends the blur-only warmup above): the
                  // "very laggy for ~1 min, then smooth" symptom wasn't
                  // just the blur shader — Home's hero gradients, card
                  // drop-shadows, and rounded-rect image clips (artwork,
                  // hero cards) are each their own distinct Skia shader,
                  // and every one of them was still compiling for the
                  // first time exactly when the user hit it while
                  // scrolling Home right after launch. Warming the same
                  // small set of primitives Home actually paints with
                  // means those first real paints on Home are no longer
                  // "first ever" paints.
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: [
                          Colors.black.withValues(alpha: 0.4),
                          Colors.transparent,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 4,
                      height: 4,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SplashOnEveryEntry extends StatelessWidget {
  final Widget child;
  const _SplashOnEveryEntry({required this.child});

  // True after the animation plays once per process lifetime.
  static bool _played = false;

  @override
  Widget build(BuildContext context) {
    if (_played) return child;
    return SplashScreen(
      key: const ValueKey('aurum_splash_once'),
      child: Builder(builder: (_) {
        // Mark as played as soon as SplashScreen hands off to its child.
        _played = true;
        return child;
      }),
    );
  }
}
