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

  // Separate from the Downloads channel above so a user who mutes download
  // progress spam doesn't also silently lose "new update available" alerts
  // (and vice versa) — matches how Spotify/Instagram-class apps split these
  // into independently-mutable channels rather than one catch-all.
  static const String _updateChannelId = 'com.aurum.music.channel.updates';
  static const String _updateChannelName = 'App Updates';
  static const String _updateChannelDesc = 'Notifies you when a new Aurum update is available';

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
        if (response.id == _updateNotificationId) {
          onUpdateNotificationTapped?.call();
          return;
        }
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

      const updateChannel = AndroidNotificationChannel(
        _updateChannelId,
        _updateChannelName,
        description: _updateChannelDesc,
        importance: Importance.high, // a real heads-up — "update available" is a rare, deliberate alert, not routine chatter
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(updateChannel);

      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  /// Fixed id for the "new update available" notification — always the
  /// same one so a second push (e.g. two releases go out before the user
  /// opens the app) updates it in place instead of stacking duplicates.
  static const int _updateNotificationId = 0x7FFFFFFD;

  /// Shown when a foreground FCM message arrives announcing a new release
  /// (background/killed-app messages are shown by the OS/FCM SDK directly
  /// from the message's own `notification` payload — this method only
  /// covers the case where the app is open, which FCM does NOT auto-display
  /// for). Tapping it routes through the same onNotificationTapped callback
  /// used by download notifications — wired in main.dart to open the
  /// Downloads screen currently; update pushes route to a dedicated
  /// callback instead so main.dart can send the user to the update dialog.
  void Function()? onUpdateNotificationTapped;

  Future<void> showUpdateAvailable({
    required String title,
    required String body,
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _updateChannelId,
        _updateChannelName,
        channelDescription: _updateChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        autoCancel: true,
      ),
    );
    await _plugin.show(_updateNotificationId, title, body, details);
  }

  /// Stable notification id per song so repeated calls update the SAME
  /// notification (Spotify-style progress bar) instead of stacking new ones.
  int _idFor(String songId) => songId.hashCode & 0x7FFFFFFF;

  // Fixed id for the batch/summary notification used when 2+ songs are
  // downloading at once (e.g. downloadPlaylist's up-to-4 concurrent
  // workers, or any future bulk-select flow). Distinct from any possible
  // _idFor(songId) collision space since songId hashes are always
  // non-negative and this uses a dedicated reserved value.
  static const int _batchId = 0x7FFFFFFE;

  // How many *individual* per-song progress notifications are considered
  // acceptable to show at once before collapsing into a single summary
  // notification instead. Keeps a single/double download feeling like the
  // familiar per-track Spotify-style bar, while anything larger (a
  // playlist batch, future bulk-select) shows one clean "12/50 songs" bar
  // instead of flooding the tray.
  static const int _maxIndividualNotifications = 2;

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

  /// Shows ONE consolidated "Downloading X of Y songs" notification that
  /// updates in place, instead of a separate notification per song.
  /// Used whenever more than [_maxIndividualNotifications] downloads are
  /// active at once (playlist batches, future bulk-select) so a 50-song
  /// download bumps the tray with exactly one updating notification, not
  /// dozens.
  Future<void> showBatchProgress({
    required int completed,
    required int total,
  }) async {
    if (total <= 0) return;
    final percent = ((completed / total) * 100).clamp(0, 100).round();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.low,
        priority: Priority.low,
        onlyAlertOnce: true,
        showProgress: true,
        maxProgress: total,
        progress: completed,
        icon: '@mipmap/ic_launcher',
        ongoing: completed < total,
        autoCancel: false,
        category: AndroidNotificationCategory.progress,
      ),
    );

    await _plugin.show(
      _batchId,
      'Downloading songs',
      '$completed of $total • $percent%',
      details,
    );
  }

  Future<void> cancelBatchProgress() async {
    await _plugin.cancel(_batchId);
  }

  /// Whether the caller should route through the batch summary notification
  /// (showBatchProgress) instead of a per-song one, given how many
  /// downloads are currently active.
  bool shouldUseBatchNotification(int activeCount) =>
      activeCount > _maxIndividualNotifications;

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
