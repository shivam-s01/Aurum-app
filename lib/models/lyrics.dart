// =============================================================================
// FILE: lib/models/lyrics.dart
// PROJECT: Aurum Music
//
// Line-synced lyrics support (LRC format). A `LyricsResult` is what
// ApiService.fetchSyncedLyrics() returns: either a list of timestamped
// `LyricLine`s (when the source had synced data) or plain text (fallback).
// =============================================================================

class LyricLine {
  final Duration time;
  final String text;

  const LyricLine({required this.time, required this.text});
}

class LyricsResult {
  /// Non-null and non-empty when we have real [mm:ss.xx] synced lines.
  final List<LyricLine>? synced;

  /// Always populated when lyrics exist at all — either the original plain
  /// lyrics, or synced lines stripped of timestamps as a display fallback.
  final String? plain;

  const LyricsResult({this.synced, this.plain});

  bool get hasSynced => synced != null && synced!.isNotEmpty;
  bool get hasAny => hasSynced || (plain != null && plain!.trim().isNotEmpty);

  /// Index of the last line whose timestamp is <= [position], or -1 if
  /// we're still before the first line.
  int activeIndexFor(Duration position) {
    if (!hasSynced) return -1;
    int lo = 0, hi = synced!.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (synced![mid].time <= position) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// Parses standard LRC text (`[mm:ss.xx] line`) into ordered LyricLines.
  /// Lines without a valid timestamp are skipped. Handles the rare case of
  /// multiple timestamps stacked on one line (e.g. "[00:12.00][00:45.00]word").
  static List<LyricLine> parseLrc(String lrc) {
    final tagPattern = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{1,3}))?\]');
    final lines = <LyricLine>[];
    for (final rawLine in lrc.split('\n')) {
      final matches = tagPattern.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      final text = rawLine.replaceAll(tagPattern, '').trim();
      for (final m in matches) {
        final minutes = int.parse(m.group(1)!);
        final seconds = int.parse(m.group(2)!);
        final fracStr = m.group(3) ?? '0';
        // Normalize fractional part to milliseconds regardless of 2 or 3 digits.
        final millis = int.parse(fracStr.padRight(3, '0').substring(0, 3));
        lines.add(LyricLine(
          time: Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
          text: text,
        ));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
