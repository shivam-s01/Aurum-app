import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/native_engine_bridge.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/audio_prefs.dart';
import 'providers/player_provider.dart';
import 'providers/library_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/download_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/followed_artists_provider.dart';
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
  // "invisible" background process and kill it far more aggressively —
  // this was the root cause of playback dying in the background even
  // after the MediaSessionService lifecycle itself was fixed. Requested
  // as early as possible (right after Flutter's binding is ready, before
  // any other init) so the OS prompt appears on first launch rather than
  // silently failing the first time a song is played. Wrapped in a
  // try/catch and never awaited-blocking on the result: if the user
  // denies it, the app must keep working (foreground playback still
  // works fine; only the background/lock-screen notification is
  // affected), never gate app startup behind this.
  try {
    await Permission.notification.request();
  } catch (_) {}

  // Wake the Saavn free-tier backend the instant the app launches — by the
  // time the user reaches Home/Search it's had a head start to warm up.
  ApiService.wakeSaavn();

  // Hive init for local DB (favorites, playlists, recently played, downloads)
  await Hive.initFlutter();

  // Apply user's image cache size preference to Flutter's in-memory image
  // cache. This is separate from cached_network_image's disk cache, but
  // controls how many decoded images are kept in RAM.
  try {
    final p = await SharedPreferences.getInstance();
    final maxImgMB = p.getDouble('max_image_cache') ?? 100.0;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        (maxImgMB * 1024 * 1024).toInt();
  } catch (_) {}

  // Supabase init — must happen before any AuthService/Supabase.instance use.
  try {
    await AuthService.init();
  } catch (_) {} // app still works fully offline/unauthenticated if this fails

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

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

  // Download progress/complete notifications. Tapping one opens Downloads.
  try {
    await NotificationService.instance.init();
    NotificationService.instance.onNotificationTapped = () {
      navigatorKey.currentState?.push(
        AurumPageRoute(builder: (_) => const DownloadsScreen()),
      );
    };
  } catch (_) {}

  runApp(AurumApp(engine: _audioEngine));
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
        ChangeNotifierProvider(create: (_) => DownloadProvider()..init()),
        ChangeNotifierProxyProvider<DownloadProvider, FavoritesProvider>(
          create: (_) => FavoritesProvider()..init(),
          update: (_, dl, fav) {
            fav?.downloadProvider = dl;
            return fav ?? (FavoritesProvider()..init()..downloadProvider = dl);
          },
        ),
        ChangeNotifierProvider(create: (_) => PlaylistProvider()..init()),
        ChangeNotifierProvider(create: (_) => FollowedArtistsProvider()..init()),
        ChangeNotifierProvider(create: (_) => AuthProvider()..init()),
        ChangeNotifierProvider(
          create: (_) {
            final pp = PremiumProvider();
            pp.init();
            // Keep AudioPrefs in sync so service-layer (ApiService) can
            // check isPremium without a BuildContext.
            pp.addListener(() => AudioPrefs.isPremium = pp.isPremium);
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
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          final isDark = themeProvider.themeMode == ThemeMode.dark ||
              themeProvider.isAmoled ||
              (themeProvider.themeMode == ThemeMode.system &&
                  WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                      Brightness.dark);

          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            systemStatusBarContrastEnforced: false,
            systemNavigationBarColor: isDark
                ? (themeProvider.isAmoled
                    ? AurumTheme.amoledBgCard
                    : AurumTheme.darkBgCard)
                : AurumTheme.lightBgCard,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarContrastEnforced: false,
          ));

          // Resolve font-aware ThemeData
          final baseLight = AurumTheme.lightTheme;
          final baseDark  = themeProvider.isAmoled
              ? AurumTheme.amoledTheme
              : AurumTheme.darkTheme;

          final lightTheme = baseLight.copyWith(
            textTheme: themeProvider.resolvedTextTheme(baseLight.textTheme),
          );
          final darkTheme = baseDark.copyWith(
            textTheme: themeProvider.resolvedTextTheme(baseDark.textTheme),
          );

          return MaterialApp(
            navigatorKey: navigatorKey,
            title: 'Aurum Music',
            debugShowCheckedModeBanner: false,
            themeMode: themeProvider.themeMode,
            theme: lightTheme,
            darkTheme: darkTheme,
            navigatorObservers: [aurumRouteObserver],
            home: AppLockScreen(child: _SplashOnEveryEntry(child: const MainShell())),
          );
        },
      ),
    );
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
