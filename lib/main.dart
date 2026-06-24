import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/audio_handler.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'providers/player_provider.dart';
import 'providers/library_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/download_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/followed_artists_provider.dart';
import 'providers/auth_provider.dart';
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
  WidgetsFlutterBinding.ensureInitialized();

  // Wake the Saavn free-tier backend the instant the app launches — by the
  // time the user reaches Home/Search it's had a head start to warm up.
  ApiService.wakeSaavn();

  // Hive init for local DB (favorites, playlists, recently played, downloads)
  await Hive.initFlutter();

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
        ChangeNotifierProvider(create: (_) => SourceProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()..init()),
        ChangeNotifierProvider(create: (_) => RecentlyPlayedProvider()..init()),
        ChangeNotifierProvider(create: (_) => DownloadProvider()..init()),
        ChangeNotifierProvider(create: (_) => PlaylistProvider()..init()),
        ChangeNotifierProvider(create: (_) => FollowedArtistsProvider()..init()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
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
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: isDark
                ? (themeProvider.isAmoled
                    ? AurumTheme.amoledBgCard
                    : AurumTheme.darkBgCard)
                : AurumTheme.lightBgCard,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ));

          // Resolve font-aware ThemeData
          final baseLight = AurumTheme.lightTheme;
          final baseDark  = themeProvider.isAmoled
              ? AurumTheme.amoledTheme
              : AurumTheme.darkTheme;

          final lightTheme = baseLight;
          final darkTheme = baseDark;

          return MaterialApp(
            navigatorKey: navigatorKey,
            title: 'Aurum Music',
            debugShowCheckedModeBanner: false,
            themeMode: themeProvider.themeMode,
            theme: lightTheme,
            darkTheme: darkTheme,
            home: AppLockScreen(child: SplashScreen(child: const MainShell())),
          );
        },
      ),
    );
  }
}
