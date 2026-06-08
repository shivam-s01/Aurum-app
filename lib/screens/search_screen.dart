import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  
  List<Song> _results = [];
  List<String> _suggestions = [];
  bool _loading = false;
  bool _showSuggestions = false;
  Timer? _debounce;
  Timer? _suggestDebounce;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    super.dispose();
  }

  void _onChanged(String q) {
    _suggestDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() { _suggestions = []; _showSuggestions = false; });
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      final s = await ApiService.suggest(q);
      if (mounted && _controller.text == q) {
        setState(() { _suggestions = s; _showSuggestions = s.isNotEmpty; });
      }
    });
  }

  void _search(String q) {
    if (q.trim().isEmpty) return;
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() { _loading = true; _showSuggestions = false; _results = []; });
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      final results = await ApiService.search(q);
      if (mounted) setState(() { _results = results; _loading = false; });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildSearchBar(),
            Expanded(
              child: _showSuggestions
                  ? _buildSuggestions()
                  : _loading
                      ? _buildLoading()
                      : _results.isNotEmpty
                          ? _buildResults()
                          : _buildEmpty(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
            child: const Text(
              'Search',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AurumTheme.divider, width: 0.5),
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          onSubmitted: _search,
          style: const TextStyle(color: AurumTheme.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Songs, artists, albums...',
            hintStyle: const TextStyle(color: AurumTheme.textMuted, fontSize: 14),
            prefixIcon: const Icon(Icons.search_rounded, color: AurumTheme.textMuted, size: 20),
            suffixIcon: _controller.text.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      _controller.clear();
                      setState(() { _results = []; _suggestions = []; _showSuggestions = false; });
                    },
                    child: const Icon(Icons.close_rounded, color: AurumTheme.textMuted, size: 18),
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
          textInputAction: TextInputAction.search,
        ),
      ),
    );
  }

  Widget _buildSuggestions() {
    return ListView.builder(
      itemCount: _suggestions.length,
      itemBuilder: (_, i) {
        return ListTile(
          leading: const Icon(Icons.search_rounded, color: AurumTheme.textMuted, size: 18),
          title: Text(
            _suggestions[i],
            style: const TextStyle(color: AurumTheme.textPrimary, fontSize: 14),
          ),
          trailing: const Icon(Icons.north_west_rounded, color: AurumTheme.textMuted, size: 16),
          dense: true,
          onTap: () {
            _controller.text = _suggestions[i];
            _search(_suggestions[i]);
          },
        );
      },
    );
  }

  Widget _buildResults() {
    return ListView.builder(
      itemCount: _results.length,
      padding: const EdgeInsets.only(bottom: 80),
      itemBuilder: (_, i) => SongTile(
        song: _results[i],
        queue: _results,
        index: i,
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: CircularProgressIndicator(
        color: AurumTheme.gold,
        strokeWidth: 2,
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_note_rounded,
            color: AurumTheme.gold.withOpacity(0.2),
            size: 64,
          ),
          const SizedBox(height: 16),
          const Text(
            'Search for your favourite songs',
            style: TextStyle(color: AurumTheme.textMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
