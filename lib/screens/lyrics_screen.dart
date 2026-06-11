import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';

class LyricsScreen extends StatelessWidget {
  final Song song;
  const LyricsScreen({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        if (song.artworkUrl.isNotEmpty) ...[
          Image.network(song.artworkUrl, fit: BoxFit.cover,
              color: Colors.black.withOpacity(0.7), colorBlendMode: BlendMode.darken),
          BackdropFilter(filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
              child: Container(color: Colors.black.withOpacity(0.6))),
        ],
        SafeArea(child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
            child: Row(children: [
              IconButton(onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white)),
              Expanded(child: Column(children: [
                Text('Lyrics', style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11, letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text(song.title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
              ])),
              const SizedBox(width: 48),
            ]),
          ),
          Expanded(child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lyrics_rounded, color: Colors.white.withOpacity(0.1), size: 80),
            const SizedBox(height: 20),
            Text('Lyrics Coming Soon', style: TextStyle(color: Colors.white.withOpacity(0.5),
                fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(song.artist, style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 14)),
          ]))),
        ])),
      ]),
    );
  }
}
