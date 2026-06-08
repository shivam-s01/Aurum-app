import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'services/audio_handler.dart';
import 'providers/player_provider.dart';
import 'theme/aurum_theme.dart';
import 'screens/main_shell.dart';

late AurumAudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Transparent status bar
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AurumTheme.bgCard,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Background audio init
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.aurum.music.channel.audio',
    androidNotificationChannelName: 'Aurum Music',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
    androidNotificationIcon: 'mipmap/ic_launcher',
  );

  _audioHandler = await AudioService.init(
    builder: () => AurumAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.aurum.music.channel.audio',
      androidNotificationChannelName: 'Aurum Music',
      androidNotificationOngoing: true,
      notificationColor: AurumTheme.gold,
    ),
  );

  runApp(AurumApp(handler: _audioHandler));
}

class AurumApp extends StatelessWidget {
  final AurumAudioHandler handler;
  const AurumApp({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerProvider(handler),
      child: MaterialApp(
        title: 'Aurum Music',
        debugShowCheckedModeBanner: false,
        theme: AurumTheme.theme,
        home: const MainShell(),
      ),
    );
  }
}
