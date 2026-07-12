import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Handles sending in-app feedback (star rating + optional message) to
/// Formspree in the background — the user never sees an email compose
/// screen or any address (theirs or ours). Also tracks the "ask after
/// 1-2 songs, then stay quiet for 12 hours" auto-prompt cooldown so the
/// prompt doesn't nag on every session.
class FeedbackService {
  FeedbackService._();

  // Formspree endpoint — submissions arrive as an email, no backend to
  // maintain and no address is ever shown to the user.
  static const _endpoint = 'https://formspree.io/f/xnjeagol';

  static const _kSongsSincePrompt = 'feedback_songs_since_prompt';
  static const _kLastPromptAt = 'feedback_last_prompt_at_ms';
  static const _kLastPromptedVersionShown = 'feedback_ever_shown';

  static const _cooldown = Duration(hours: 12);
  static const _songsBeforePrompt = 2; // ask after 1-2 songs

  /// Call this every time a track finishes starting playback. Returns
  /// true when the auto-prompt should be shown right now (and resets
  /// its own counters), false otherwise.
  static Future<bool> onSongPlayed() async {
    final prefs = await SharedPreferences.getInstance();

    final lastPromptMs = prefs.getInt(_kLastPromptAt) ?? 0;
    final sinceLast = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(lastPromptMs),
    );
    if (lastPromptMs != 0 && sinceLast < _cooldown) {
      // Still within the 12-hour quiet period — don't even count songs,
      // just wait it out.
      return false;
    }

    final songCount = (prefs.getInt(_kSongsSincePrompt) ?? 0) + 1;

    if (songCount >= _songsBeforePrompt) {
      await prefs.setInt(_kSongsSincePrompt, 0);
      await prefs.setInt(_kLastPromptAt, DateTime.now().millisecondsSinceEpoch);
      await prefs.setBool(_kLastPromptedVersionShown, true);
      return true;
    }

    await prefs.setInt(_kSongsSincePrompt, songCount);
    return false;
  }

  /// Sends the feedback silently in the background. Returns true on
  /// success. Never throws — callers show a friendly message either way
  /// after a short delay so the UX doesn't depend on network timing.
  static Future<bool> submit({
    required int rating,
    String? message,
    String? appVersion,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'rating': '$rating / 5',
              'message': (message == null || message.trim().isEmpty)
                  ? '(no additional comments)'
                  : message.trim(),
              'app_version': appVersion ?? 'unknown',
              'subject': 'Aurum Feedback — $rating★',
            }),
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200 || response.statusCode == 202;
    } catch (_) {
      return false;
    }
  }
}
