import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';

class SongInfoScreen extends StatelessWidget {
  final Song song;
  final Color bgColor;
  const SongInfoScreen({super.key, required this.song, required this.bgColor});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        if (song.artworkUrl.isNotEmpty) ...[
          Image.network(song.artworkUrl, fit: BoxFit.cover,
              color: Colors.black.withOpacity(0.7), colorBlendMode: BlendMode.darken),
          BackdropFilter(filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
              child: Container(color: Colors.black.withOpacity(0.55))),
        ],
        SafeArea(child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
            child: Row(children: [
              IconButton(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white)),
              Expanded(child: Column(children: [
                Text('Song Info', style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11, letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text(song.title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
              ])),
              const SizedBox(width: 48),
            ]),
          ),
          const SizedBox(height: 8),
          // Artwork — uses AurumArtwork for consistent premium fadeIn instead
          // of a raw Image.network that pops in abruptly.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 80),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: 1,
                child: song.artworkUrl.isNotEmpty
                    ? AurumArtwork(
                        url: song.artworkUrl,
                        size: double.infinity,
                        borderRadius: 16,
                      )
                    : Container(
                        color: bgColor,
                        child: const Icon(Icons.music_note_rounded, color: AurumTheme.gold, size: 48),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                _infoCard([
                  _row('Title', song.title),
                  _row('Artist', song.artist),
                  if (song.album.isNotEmpty) _row('Album', song.album),
                ]),
                const SizedBox(height: 12),
                _infoCard([
                  if (song.year != null && song.year!.isNotEmpty) _row('Year', song.year!),
                  if (song.language != null && song.language!.isNotEmpty) _row('Language', song.language!),
                  _row('Duration', song.durationString),
                  _row('Source', song.isLocal ? 'Local Library' : 'Online Stream'),
                ]),
              ],
            ),
          ),
        ])),
      ]),
    );
  }

  Widget _infoCard(List<Widget> rows) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Column(children: rows),
        ),
      ),
    );
  }

  Widget _row(String key, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      child: Row(children: [
        SizedBox(width: 80, child: Text(key,
            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13))),
        Expanded(child: Text(val,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500))),
      ]),
    );
  }
}
