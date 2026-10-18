import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/profanity_filter.dart';

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
  static const int maxMessageLength = 500;

  // Soft-warning tracking (device-level; nothing is actually blocked yet —
  // this only decides which red message to show).
  static const _kAbuseLog = 'feedback_abuse_attempts_ms';
  static const _kSendLog = 'feedback_recent_sends_ms';
  static const _abuseWindow = Duration(hours: 24);
  static const _sendWindow = Duration(minutes: 10);
  static const _abuseStrikesForWarning = 2; // 2nd blocked attempt onward
  static const _sendsBeforeWarning = 2; // warn on the 3rd+ message

  static const String abuseMessage =
      'Please keep your feedback respectful — abusive language is not allowed.';
  static const String spamWarning =
      "Don't spam or abuse. Your ID and device may be blocked.";

  static Future<List<int>> _recent(
      SharedPreferences prefs, String key, Duration window) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (prefs.getStringList(key) ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .where((t) => now - t < window.inMilliseconds)
        .toList();
  }

  /// UI entry point: runs [validate]; if the text is abusive, records the
  /// attempt and returns the message to show in red. Repeated abuse gets
  /// the stronger "may be blocked" warning. Returns null if the text is OK.
  static Future<String?> screen(String? message) async {
    final problem = validate(message);
    if (problem == null) return null;
    if (problem != abuseMessage) return problem; // e.g. too long
    try {
      final prefs = await SharedPreferences.getInstance();
      final log = await _recent(prefs, _kAbuseLog, _abuseWindow);
      log.add(DateTime.now().millisecondsSinceEpoch);
      await prefs.setStringList(_kAbuseLog, log.map((e) => '$e').toList());
      if (log.length >= _abuseStrikesForWarning) return spamWarning;
    } catch (_) {}
    return problem;
  }

  /// Call after a successful send. Returns true when this was the 3rd (or
  /// later) message within 10 minutes, i.e. the spam warning should show.
  /// Sending is never blocked — this is only a warning.
  static Future<bool> recordSendAndCheckSpam() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final log = await _recent(prefs, _kSendLog, _sendWindow);
      log.add(DateTime.now().millisecondsSinceEpoch);
      await prefs.setStringList(_kSendLog, log.map((e) => '$e').toList());
      return log.length > _sendsBeforeWarning;
    } catch (_) {
      return false;
    }
  }

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

  /// Returns a user-facing error if [message] can't be sent, else null.
  /// Only abuse is blocked — signed-in users can send as often as they like.
  static String? validate(String? message) {
    final msg = (message ?? '').trim();
    if (msg.length > maxMessageLength) {
      return 'Message is too long (max $maxMessageLength characters).';
    }
    if (ProfanityFilter.containsProfanity(msg)) {
      return abuseMessage;
    }
    return null;
  }

  /// Sends the feedback silently in the background. Returns true on
  /// success. Never throws — callers show a friendly message either way
  /// after a short delay so the UX doesn't depend on network timing.
  static Future<bool> submit({
    required int rating,
    String? userId,
    String? userEmail,
    String? message,
    String? appVersion,
  }) async {
    if (validate(message) != null) return false; // never send abuse
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
              'user_id': userId ?? 'unknown',
              'user_email': userEmail ?? 'unknown',
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
