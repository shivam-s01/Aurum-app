import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';

/// Handles "a new Aurum update is available" push notifications — the
/// piece UpdateService (checkForUpdate) can't cover on its own, since that
/// only runs while the app is actually open. This is what lets a user get
/// notified even with the app fully killed, the same way Spotify/
/// Instagram-class apps surface release/feature announcements.
///
/// How a release reaches a device:
///   1. `flutter build` pushes a `[release]` commit → build.yml creates a
///      GitHub release (existing flow, unchanged).
///   2. A new CI step (see build.yml) then POSTs to FCM's HTTP v1 API,
///      targeting the `updates` topic every install below subscribes to.
///   3. FCM delivers it — killed/background apps get an OS-level
///      notification straight from the message's own `notification`
///      payload (no app code runs at all for that case, which is exactly
///      why this works even when killed); a foreground app instead gets
///      an `onMessage` callback here, since FCM does NOT auto-display
///      notifications while the app is in the foreground.
///
/// Requires android/app/google-services.json from the Firebase console —
/// see FCM_SETUP.md. Every method below fails soft (try/catch, never
/// throws) so a misconfigured/missing Firebase project degrades to "no
/// push notifications" rather than crashing the app.
class UpdatePushService {
  UpdatePushService._();
  static final UpdatePushService instance = UpdatePushService._();

  // Every install subscribes to this single topic — there's no per-user
  // targeting need for "a new version exists", so a topic (vs. tracking
  // individual device tokens server-side) keeps this entirely serverless:
  // the CI step just POSTs to `/topics/updates`, no token database to run
  // or maintain.
  static const String _updatesTopic = 'updates';

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      await Firebase.initializeApp();

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      await messaging.subscribeToTopic(_updatesTopic);

      // Foreground: FCM does not show a system notification on its own
      // while the app is open, so this is the only place a push actually
      // needs to be turned into a visible notification manually — reuses
      // NotificationService's existing "App Updates" channel rather than
      // a separate one, so mute/importance settings stay in one place.
      FirebaseMessaging.onMessage.listen((message) {
        final title = message.notification?.title ?? 'Update available';
        final body = message.notification?.body ??
            'A new version of Aurum is ready to install.';
        NotificationService.instance.showUpdateAvailable(title: title, body: body);
      });

      _initialized = true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aurum] UpdatePushService: init failed (push notifications disabled this session): $e');
      }
    }
  }
}
