import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/mini_player.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'full_player_screen.dart';
import '../providers/player_provider.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  bool _isOffline = false;

  void _switchToOffline() => setState(() => _isOffline = true);
  void _switchToOnline() => setState(() => _isOffline = false);

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        return Stack(
          children: [
            Scaffold(
              backgroundColor: AurumTheme.bgOf(context),
              body: IndexedStack(
                index: _tab,
                children: [
                  _isOffline
                      ? LibraryScreen(onSwitchToOnline: _switchToOnline)
                      : HomeScreen(onSwitchToOffline: _switchToOffline),
                  const SearchScreen(),
                ],
              ),
              bottomNavigationBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MiniPlayer(),
                  _buildBottomNav(context),
                ],
              ),
            ),
            if (player.showFullPlayer) const FullPlayerScreen(),
          ],
        );
      },
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        border: Border(top: BorderSide(color: AurumTheme.dividerOf(context), width: 0.5)),
      ),
      child: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home_rounded), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search_outlined), activeIcon: Icon(Icons.search_rounded), label: 'Search'),
        ],
      ),
    );
  }
}
