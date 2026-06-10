import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/audio_handler.dart';
import 'providers/player_provider.dart';
import 'providers/library_provider.dart';
import 'providers/theme_provider.dart';
import 'theme/aurum_theme.dart';
import 'screens/main_shell.dart';
import 'screens/splash_screen.dart';
import 'screens/settings_screen.dart';

late AurumAudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp]);

  try {
    await JustAudioBackground.init(
      androidNotificationChannelId:
          'com.aurum.music.channel.audio',
      androidNotificationChannelName: 'Aurum Music',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ).timeout(const Duration(seconds: 5));
  } catch (_) {}

  try {
    _audioHandler = await AudioService.init(
      builder: () => AurumAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            'com.aurum.music.channel.audio',
        androidNotificationChannelName: 'Aurum Music',
        androidNotificationOngoing: true,
        notificationColor: AurumTheme.gold,
      ),
    ).timeout(const Duration(seconds: 5));
  } catch (_) {
    _audioHandler = AurumAudioHandler();
  }

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
        ChangeNotifierProvider(
            create: (_) => PlayerProvider(handler)),
        // LibraryProvider now loads everything internally
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            title: 'Aurum Music',
            debugShowCheckedModeBanner: false,
            themeMode: themeProvider.themeMode,
            theme: AurumTheme.lightTheme,
            darkTheme: themeProvider.isAmoled
                ? AurumTheme.amoledTheme
                : AurumTheme.darkTheme,
            routes: {
              '/settings': (_) => const SettingsScreen(),
            },
            home: SplashScreen(child: const MainShell()),
          );
        },
      ),
    );
  }
}
