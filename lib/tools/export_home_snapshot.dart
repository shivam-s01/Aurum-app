// =============================================================================
// FILE: lib/tools/export_home_snapshot.dart
// PROJECT: Astra Music
// PURPOSE: ONE-TIME EXPORT TOOL — not part of the shipping app.
//
// Run this once (see instructions below) to generate a real, live snapshot
// of the home feed and save it as assets/data/home_snapshot.json. That file
// then ships INSIDE the app bundle, so a brand-new install can paint real
// content at 0ms (no network round-trip) before the live fetch even starts.
//
// WHY A SEPARATE TOOL INSTEAD OF HARDCODED SONGS: song metadata (artwork
// URLs, artist channel ids, correct ids matching this app's own ID format)
// has to come from the real API — hand-typing song names risks wrong/broken
// data. This tool calls the exact same ApiService.fetchHomeStreaming that
// the real home screen uses, so the bundled snapshot is byte-for-byte real
// app data, just captured once and frozen into an asset.
//
// STREAM URLS DO NOT GO STALE: resolveStreamUrl() in api_service.dart is
// called lazily at play-time from the song's id/title/artist — the
// streamUrl baked into this JSON is never used for playback, so there's no
// "dead link" risk even if a user installs the app months after this file
// was generated. See fetchArtistStreaming's docs for the same point.
//
// HOW TO RUN (Termux):
//   1) Temporarily point your app's main() at this file's main() OR run:
//        flutter run -t lib/tools/export_home_snapshot.dart
//      on a real device/emulator with a working internet connection.
//   2) Wait for the console to print "SNAPSHOT WRITTEN: <path>" — this can
//      take up to ~30s since it waits for a genuinely complete fetch, not
//      a fast partial one (we WANT a full, good snapshot here, unlike the
//      live app which prefers speed).
//   3) Pull the file off the device:
//        adb pull "<path printed above>" ./home_snapshot.json
//      (or use path_provider's printed path with Termux's own storage
//      access if running directly on-device without adb).
//   4) Move it into the repo at assets/data/home_snapshot.json, add
//      'assets/data/home_snapshot.json' under pubspec.yaml's assets: list,
//      commit, and rebuild the real app normally.
//   5) Re-run this whenever you want to refresh the bundled snapshot
//      (e.g. every few months, or before a big release) — it's just a
//      build-time asset, never fetched at runtime.
// =============================================================================

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../models/song.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ExportRunnerApp());
}

class _ExportRunnerApp extends StatefulWidget {
  const _ExportRunnerApp();
  @override
  State<_ExportRunnerApp> createState() => _ExportRunnerAppState();
}

class _ExportRunnerAppState extends State<_ExportRunnerApp> {
  String _status = 'Starting export...';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final sections = <SongSection>[];
    try {
      setState(() => _status = 'Fetching live home feed (this can take up to 30s — waiting for a COMPLETE fetch, not a fast partial one)...');
      // Deliberately no fastFirstSection here and no early return — this
      // tool wants the best, fullest snapshot possible since it only runs
      // once in a while, not the fastest-possible one like the live app.
      await ApiService.fetchHomeStreaming(
        onSection: (section) {
          final idx = sections.indexWhere((s) => s.id == section.id);
          if (idx != -1) {
            sections[idx] = section;
          } else {
            sections.add(section);
          }
          setState(() => _status = 'Fetching... ${sections.length} sections so far (latest: "${section.title}", ${section.songs.length} songs)');
        },
      ).timeout(const Duration(seconds: 45), onTimeout: () {
        setState(() => _status = 'Timed out at 45s — writing whatever was collected (${sections.length} sections).');
      });

      if (sections.isEmpty) {
        setState(() => _status = 'FAILED: no sections were fetched at all. Check your internet connection and retry.');
        return;
      }

      final json = jsonEncode(sections.map((s) => s.toJson()).toList());
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/home_snapshot.json');
      await file.writeAsString(json);

      final totalSongs = sections.fold<int>(0, (sum, s) => sum + s.songs.length);
      setState(() => _status =
          'SNAPSHOT WRITTEN: ${file.path}\n\n'
          '${sections.length} sections, $totalSongs songs total.\n\n'
          'Pull it with:\n adb pull "${file.path}" ./home_snapshot.json\n\n'
          'Then move it to assets/data/home_snapshot.json in your repo.');
    } catch (e) {
      setState(() => _status = 'FAILED: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              _status,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
