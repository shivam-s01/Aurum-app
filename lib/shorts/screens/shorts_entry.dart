import 'package:flutter/material.dart';
import '../services/shorts_prefs.dart';
import 'shorts_feed_screen.dart';
import 'shorts_onboarding_welcome.dart';

/// Entry gate for the Shorts tab: shows onboarding once, then always
/// drops straight into the feed. Placed in the bottom nav in place of
/// a plain screen so MainShell's IndexedStack/list pattern stays
/// untouched — this widget alone decides what to render.
class ShortsEntry extends StatefulWidget {
  const ShortsEntry({super.key});

  @override
  State<ShortsEntry> createState() => _ShortsEntryState();
}

class _ShortsEntryState extends State<ShortsEntry> {
  bool? _onboarded;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final done = await ShortsPrefs.isOnboarded();
    if (mounted) setState(() => _onboarded = done);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarded == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white38),
        ),
      );
    }
    return _onboarded! ? const ShortsFeedScreen() : const ShortsWelcomeScreen();
  }
}
