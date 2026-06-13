import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../models/song.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lib = context.read<LibraryProvider>();
      if (!lib.hasLoaded) lib.load();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LibraryProvider>(
      builder: (context, lib, _) {
        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          body: SafeArea(
            child: Column(
              children: [
                _buildHeader(context, lib),
                if (_searching) _buildSearchBar(context, lib),
                Expanded(child: _buildBody(context, lib)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, LibraryProvider lib) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          Text(
            'Library',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const Spacer(),
          if (lib.status == LibraryStatus.loaded) ...[
            IconButton(
              icon: Icon(
                _searching ? Icons.search_off_rounded : Icons.search_rounded,
                color: _searching ? AurumTheme.gold : AurumTheme.textSecondaryOf(context),
              ),
              onPressed: () {
                setState(() => _searching = !_searching);
                if (!_searching) {
                  _searchCtrl.clear();
                  lib.clearSearch();
                }
              },
            ),
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: AurumTheme.textSecondaryOf(context)),
              onPressed: lib.refresh,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, LibraryProvider lib) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _searchCtrl,
        autofocus: true,
        style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14),
        onChanged: lib.setSearch,
        decoration: InputDecoration(
          hintText: 'Search your library...',
          hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
          prefixIcon: Icon(Icons.search_rounded, color: AurumTheme.textMutedOf(context), size: 20),
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.close_rounded, color: AurumTheme.textMutedOf(context), size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    lib.clearSearch();
                  },
                )
              : null,
          filled: true,
          fillColor: AurumTheme.bgElevatedOf(context),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, LibraryProvider lib) {
    switch (lib.status) {
      case LibraryStatus.idle:
      case LibraryStatus.loading:
        return const Center(
          child: CircularProgressIndicator(color: AurumTheme.gold, strokeWidth: 2),
        );
      case LibraryStatus.noPermission:
        return _buildPermissionPrompt(context, lib);
      case LibraryStatus.empty:
        return _buildEmptyState(context);
      case LibraryStatus.loaded:
        if (_searching) return _buildSearchResults(context, lib);
        return _buildSections(context, lib);
    }
  }

  Widget _buildSections(BuildContext context, LibraryProvider lib) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 140),
      itemCount: lib.sections.length,
      itemBuilder: (context, i) => _SectionBlock(section: lib.sections[i]),
    );
  }

  Widget _buildSearchResults(BuildContext context, LibraryProvider lib) {
    final results = lib.filteredSongs;
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No songs found',
          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 140),
      itemCount: results.length,
      itemBuilder: (context, i) => SongTile(song: results[i], queue: results, index: i),
    );
  }

  Widget _buildPermissionPrompt(BuildContext context, LibraryProvider lib) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AurumTheme.bgElevatedOf(context),
                shape: BoxShape.circle,
                border: Border.all(color: AurumTheme.gold.withOpacity(0.3)),
              ),
              child: const Icon(Icons.folder_rounded, color: AurumTheme.gold, size: 32),
            ),
            const SizedBox(height: 20),
            Text(
              'Allow Music Access',
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Aurum needs permission to read your music library.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: lib.load,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                decoration: BoxDecoration(
                  gradient: AurumTheme.goldGradient,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Text(
                  'Grant Permission',
                  style: TextStyle(
                    color: AurumTheme.bg,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_off_rounded, color: AurumTheme.textMutedOf(context), size: 48),
            const SizedBox(height: 16),
            Text(
              'No music found',
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add songs to your device and they\'ll appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AurumTheme.textMutedOf(context),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionBlock extends StatelessWidget {
  final SongSection section;
  const _SectionBlock({required this.section});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 10),
          child: Row(
            children: [
              Text(
                section.title,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${section.songs.length} songs',
                style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12),
              ),
            ],
          ),
        ),
        ...section.songs.asMap().entries.map(
              (e) => SongTile(song: e.value, queue: section.songs, index: e.key),
            ),
        const SizedBox(height: 4),
        Divider(color: AurumTheme.dividerOf(context), height: 1),
      ],
    );
  }
}
