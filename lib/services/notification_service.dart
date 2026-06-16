import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Handles all download-related notifications:
///  - A single, updating "Downloading..." progress notification (Spotify-style)
///  - A "Download complete" notification once finished
///  - Tap-to-open routing back into the app (Downloads screen)
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const String _channelId = 'com.aurum.music.channel.downloads';
  static const String _channelName = 'Downloads';
  static const String _channelDesc = 'Shows progress while songs are downloading';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Callback invoked when the user taps a download notification.
  /// Wired up in main.dart to navigate to the Downloads screen.
  void Function()? onNotificationTapped;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        onNotificationTapped?.call();
      },
    );

    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.low, // low = no sound/heads-up spam while progress updates
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  /// Stable notification id per song so repeated calls update the SAME
  /// notification (Spotify-style progress bar) instead of stacking new ones.
  int _idFor(String songId) => songId.hashCode & 0x7FFFFFFF;

  Future<void> showProgress({
    required String songId,
    required String title,
    required int percent, // 0-100
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.low,
        priority: Priority.low,
        onlyAlertOnce: true,
        showProgress: true,
        maxProgress: 100,
        progress: percent,
        icon: '@mipmap/ic_launcher',
        ongoing: percent < 100,
        autoCancel: false,
        category: AndroidNotificationCategory.progress,
      ),
    );

    await _plugin.show(
      _idFor(songId),
      'Downloading',
      '$title • $percent%',
      details,
    );
  }

  Future<void> showCompleted({
    required String songId,
    required String title,
  }) async {
    // Cancel the progress notification, then fire a clean "complete" one.
    await _plugin.cancel(_idFor(songId));

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
        autoCancel: true,
      ),
    );

    await _plugin.show(
      _idFor(songId) + 1, // different id so it doesn't collide with progress one mid-cancel
      'Download complete',
      title,
      details,
    );
  }

  Future<void> showFailed({
    required String songId,
    required String title,
  }) async {
    await _plugin.cancel(_idFor(songId));

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
        autoCancel: true,
      ),
    );

    await _plugin.show(
      _idFor(songId) + 1,
      'Download failed',
      title,
      details,
    );
  }

  Future<void> cancelProgress(String songId) async {
    await _plugin.cancel(_idFor(songId));
  }
}
