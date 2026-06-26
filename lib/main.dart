import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/audio_handler.dart';
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

late AurumAudioHandler _audioHandler;

/// Global navigator key — lets the notification-tap callback (which fires
/// outside the widget tree) push the Downloads screen.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  runZonedGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Wake the Saavn free-tier backend the instant the app launches — by the
  // time the user reaches Home/Search it's had a head start to warm up.
  ApiService.wakeSaavn();

  // Hive init for local DB (favorites, playlists, recently played, downloads)
  await Hive.initFlutter();

  // Supabase init — must happen before any AuthService/Supabase.instance use.
  try {
    await AuthService.init();
  } catch (_) {} // app still works fully offline/unauthenticated if this fails

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  try {
    _audioHandler = await AudioService.init(
      builder: () => AurumAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.aurum.music.channel.audio',
        androidNotificationChannelName: 'Aurum Music',
        androidNotificationOngoing: true,
        notificationColor: AurumTheme.gold,
      ),
    ).timeout(const Duration(seconds: 5));
  } catch (_) {
    _audioHandler = AurumAudioHandler();
  }

  // Download progress/complete notifications. Tapping one opens Downloads.
  try {
    await NotificationService.instance.init();
    NotificationService.instance.onNotificationTapped = () {
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const DownloadsScreen()),
      );
    };
  } catch (_) {}

  runApp(AurumApp(handler: _audioHandler));
  }, (error, stack) {
    debugPrint('[Aurum] Uncaught error: $error\n$stack');
  });
}

class AurumApp extends StatelessWidget {
  final AurumAudioHandler handler;
  const AurumApp({super.key, required this.handler});

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
            // FIX: handler.stop() is async and was called fire-and-forget
            // with no error handling. If the player has nothing loaded
            // (e.g. user toggles source before playing anything) or the
            // native ExoPlayer call throws, that became an unhandled
            // Future rejection that crashed the app the instant the
            // Online/Offline pill was tapped. Now any failure is caught
            // and swallowed — stopping playback is best-effort, it should
            // never be able to take down the UI.
            sp.onSourceChanged = () {
              handler.stop().catchError((e, st) {
                debugPrint('[Aurum] stop() on source change failed: $e');
              });
            };
            sp.init();
            return sp;
          },
        ),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()..init()),
        ChangeNotifierProvider(create: (_) => RecentlyPlayedProvider()..init()),
        ChangeNotifierProvider(create: (_) => DownloadProvider()..init()),
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
        ChangeNotifierProxyProvider<RecentlyPlayedProvider, PlayerProvider>(
          create: (_) => PlayerProvider(handler),
          update: (_, recentlyPlayed, player) {
            player?.updateRecentlyPlayed(recentlyPlayed);
            return player ?? PlayerProvider(handler, recentlyPlayedProvider: recentlyPlayed);
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
// FIX: SplashScreen only ever played once per Dart VM lifetime. On Android,
// pressing Home (or swiping to recents without force-closing) does NOT kill
// the process — especially here, since the audio_service background service
// (`stopWithTask="false"`) keeps the app process alive deliberately so music
// keeps playing. Reopening the app from the launcher/recents then just
// resumes the existing Activity; main() never re-runs, so
// SplashScreen.initState() never fires again and the user lands straight on
// whatever screen was already showing — no animation, and if that screen
// was mid-crash/blank, it stays that way until a real process kill.
//
// This wrapper watches app lifecycle directly and gives SplashScreen a fresh
// ValueKey every time the app transitions from backgrounded → resumed (not
// just on cold start), forcing Flutter to throw away the old splash State
// and build a brand new one — replaying the full intro animation every
// single time the user opens the app, exactly like a true fresh start.
//
// A real "closed it then reopened" press always passes through `paused`
// (or `inactive` → `paused` if backgrounded for any meaningful time), so
// this fires for both real cold starts AND resume-from-background, without
// needing any extra permission or platform channel.
class _SplashOnEveryEntry extends StatefulWidget {
  final Widget child;
  const _SplashOnEveryEntry({required this.child});

  @override
  State<_SplashOnEveryEntry> createState() => _SplashOnEveryEntryState();
}

class _SplashOnEveryEntryState extends State<_SplashOnEveryEntry>
    with WidgetsBindingObserver {
  // Changing this key forces SplashScreen to rebuild as a brand-new widget
  // instance, discarding its old State (and therefore its old, already-
  // completed AnimationController) and starting the intro from frame zero.
  Key _splashKey = UniqueKey();
  bool _wasBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _wasBackgrounded = true;
      return;
    }

    if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      // Fresh key → fresh SplashScreen State → full animation replays.
      setState(() => _splashKey = UniqueKey());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SplashScreen(key: _splashKey, child: widget.child);
  }
}
