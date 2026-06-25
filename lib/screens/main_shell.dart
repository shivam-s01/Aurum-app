import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../theme/aurum_theme.dart';
import '../widgets/mini_player.dart';
import '../models/song.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import '../providers/player_provider.dart'; // kept for _saveQueue()
import '../services/update_service.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _tab = 0;

  // Keep screens alive so tab switches don't rebuild from scratch
  final _screens = const [
    _KeepAliveScreen(child: HomeScreen()),
    _KeepAliveScreen(child: SearchScreen()),
    _KeepAliveScreen(child: LibraryScreen()),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Update check
      final prefs = await SharedPreferences.getInstance();
      final checkUpdates = prefs.getBool('check_updates') ?? true;
      if (checkUpdates && mounted) {
        await UpdateService.checkForUpdate(context);
      }

      // Keep Queue restore disabled — app opens clean, nothing shows until
      // the user explicitly plays a song.
      // await _restoreQueueIfNeeded();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Save queue when app goes to background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveQueue();
    }
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final keepQueue = prefs.getBool('keep_queue') ?? true;
    if (!keepQueue) return;

    final player = context.read<PlayerProvider>();
    if (player.queue.isEmpty) return;

    try {
      final queueJson =
          jsonEncode(player.queue.map((s) => s.toJson()).toList());
      await prefs.setString('saved_queue', queueJson);
      await prefs.setInt('saved_queue_index', player.currentIndex);
    } catch (_) {}
  }

  Future<void> _restoreQueueIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final keepQueue = prefs.getBool('keep_queue') ?? true;
    if (!keepQueue) return;

    final queueJson = prefs.getString('saved_queue');
    if (queueJson == null || queueJson.isEmpty) return;

    try {
      final List<dynamic> decoded = jsonDecode(queueJson);
      final songs = decoded
          .whereType<Map<String, dynamic>>()
          .map(Song.fromJson)
          .toList();
      if (songs.isEmpty) return;

      final index = (prefs.getInt('saved_queue_index') ?? 0)
          .clamp(0, songs.length - 1);

      if (!mounted) return;
      await context.read<PlayerProvider>().restoreQueueSilently(songs, index);
    } catch (_) {
      // Corrupt saved queue — clear it
      await prefs.remove('saved_queue');
      await prefs.remove('saved_queue_index');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: IndexedStack(index: _tab, children: _screens),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          Container(
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              border: Border(
                  top: BorderSide(
                      color: AurumTheme.dividerOf(context), width: 0.5)),
            ),
            child: BottomNavigationBar(
              currentIndex: _tab,
              onTap: (i) => setState(() => _tab = i),
              backgroundColor: Colors.transparent,
              elevation: 0,
              selectedLabelStyle: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 11),
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined),
                    activeIcon: Icon(Icons.home_rounded),
                    label: 'Home'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.search_outlined),
                    activeIcon: Icon(Icons.search_rounded),
                    label: 'Search'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.library_music_outlined),
                    activeIcon: Icon(Icons.library_music_rounded),
                    label: 'Library'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


// Keeps tab screens alive so switching tabs doesn't rebuild them from scratch
class _KeepAliveScreen extends StatefulWidget {
  final Widget child;
  const _KeepAliveScreen({required this.child});
  @override
  State<_KeepAliveScreen> createState() => _KeepAliveScreenState();
}

class _KeepAliveScreenState extends State<_KeepAliveScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
