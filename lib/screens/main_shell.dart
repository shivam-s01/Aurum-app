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
  bool _isOffline = false; // false = Online Stream, true = Offline Library

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
                  // Tab 0 switches between Online home and Offline library
                  _isOffline ? const LibraryScreen() : const HomeScreen(),
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
        border: Border(
          top: BorderSide(color: AurumTheme.dividerOf(context), width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Online / Offline toggle pill ──────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: _StreamToggle(
              isOffline: _isOffline,
              onToggle: (val) => setState(() => _isOffline = val),
            ),
          ),
          // ── Bottom navigation bar ─────────────────────────────────
          BottomNavigationBar(
            currentIndex: _tab,
            onTap: (i) => setState(() => _tab = i),
            backgroundColor: Colors.transparent,
            elevation: 0,
            selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 11),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                activeIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.search_outlined),
                activeIcon: Icon(Icons.search_rounded),
                label: 'Search',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Online / Offline toggle pill ─────────────────────────────────────────────

class _StreamToggle extends StatelessWidget {
  final bool isOffline;
  final ValueChanged<bool> onToggle;

  const _StreamToggle({required this.isOffline, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Row(
        children: [
          _pill(
            context: context,
            label: 'Online Stream',
            icon: Icons.wifi_rounded,
            active: !isOffline,
            onTap: () => onToggle(false),
          ),
          _pill(
            context: context,
            label: 'Offline Library',
            icon: Icons.download_done_rounded,
            active: isOffline,
            onTap: () => onToggle(true),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required BuildContext context,
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: active ? AurumTheme.gold : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 13,
                color: active ? AurumTheme.bg : AurumTheme.textMutedOf(context),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? AurumTheme.bg : AurumTheme.textMutedOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
