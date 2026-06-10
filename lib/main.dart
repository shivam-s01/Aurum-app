import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/audio_handler.dart';
import 'providers/player_provider.dart';
import 'providers/library_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/source_provider.dart';
import 'providers/theme_provider.dart';
import 'theme/aurum_theme.dart';
import 'screens/main_shell.dart';
import 'screens/splash_screen.dart';

late AurumAudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Step 1: Notification
  await Permission.notification.request();

  // Step 2: Storage (local music)
  await Permission.audio.request();
  await Permission.storage.request();

  // Step 3: Battery optimization bypass — background kill band
  if (!(await Permission.ignoreBatteryOptimizations.isGranted)) {
    await Permission.ignoreBatteryOptimizations.request();
  }

  // Step 4: AudioService init
  _audioHandler = await AudioService.init(
    builder: () => AurumAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.aurum.music.channel.audio',
      androidNotificationChannelName: 'Aurum Music',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
      notificationColor: Color(0xFFD4AF37),
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidShowNotificationBadge: true,
    ),
  );

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
        ChangeNotifierProvider(create: (_) => PlayerProvider(handler)),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()..init()),
        ChangeNotifierProvider(create: (_) => SourceProvider()..init()),
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
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: isDark
                ? (themeProvider.isAmoled ? AurumTheme.amoledBgCard : AurumTheme.darkBgCard)
                : AurumTheme.lightBgCard,
            systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          ));

          return MaterialApp(
            title: 'Aurum Music',
            debugShowCheckedModeBanner: false,
            themeMode: themeProvider.themeMode,
            theme: AurumTheme.lightTheme,
            darkTheme: themeProvider.isAmoled
                ? AurumTheme.amoledTheme
                : AurumTheme.darkTheme,
            home: SplashScreen(child: const MainShell()),
          );
        },
      ),
    );
  }
}
