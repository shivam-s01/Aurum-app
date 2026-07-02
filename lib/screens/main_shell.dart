import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../theme/aurum_theme.dart';
import '../widgets/mini_player.dart';
import '../models/song.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import '../providers/player_provider.dart';
import '../services/update_service.dart';
import '../services/audio_prefs.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _tab = 0;

  final _screens = const [
    HomeScreen(),
    SearchScreen(),
    LibraryScreen(),
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

  // Save queue when app goes to background. Also re-check Android's real
  // system Data Saver state on resume — Android doesn't reliably notify
  // background apps of Data Saver changes, so the moment the user is back
  // in the app (having possibly just flipped it in system settings) is the
  // right time to refresh, ensuring the very next song resolve honors
  // whatever the user's system-level choice currently is.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveQueue();
    } else if (state == AppLifecycleState.resumed) {
      AudioPrefs.refreshSystemDataSaver();
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
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
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
                  onTap: (i) {
                    // FIX: SearchScreen lives inside an IndexedStack — never
                    // disposed, just hidden. Unfocus on EVERY tab tap (not
                    // just when leaving search) so the keyboard never bleeds
                    // through to other screens. The primary keyboard issue was:
                    // user opens search → types → switches tab → keyboard hides
                    // visually but focus is still held by the TextField → any
                    // rebuild (song change, mini-player update) causes Android
                    // to resurface the keyboard. Calling primaryFocus?.unfocus()
                    // with UnfocusDisposition.scope drops focus from the entire
                    // widget tree, not just the current scope — this is more
                    // aggressive than FocusScope.of(context).unfocus() and
                    // correctly handles the case where focus is held by a
                    // widget in a different branch of the tree (IndexedStack).
                    primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
                    // OS-level keyboard kill — most reliable way to ensure
                    // keyboard never bleeds through from IndexedStack branches.
                    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
                    setState(() => _tab = i);
                  },
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
      },
    );
  }
}
