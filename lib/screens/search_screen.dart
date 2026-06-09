import 'package:flutter/material.dart';
import 'dart:async';
import '../models/song.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_loader.dart';

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
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      final s = await ApiService.suggest(q);
      if (mounted && _controller.text == q) {
        setState(() {
          _suggestions = s;
          _showSuggestions = s.isNotEmpty;
        });
      }
    });
  }

  void _search(String q) {
    if (q.trim().isEmpty) return;
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _showSuggestions = false;
      _results = [];
    });
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      final results = await ApiService.search(q);
      if (mounted) setState(() { _results = results; _loading = false; });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            _buildSearchBar(context),
            Expanded(
              child: _showSuggestions
                  ? _buildSuggestions(context)
                  : _loading
                      ? const AurumLoaderScreen()
                      : _results.isNotEmpty
                          ? _buildResults()
                          : _buildEmpty(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
            child: const Text(
              'Search',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          onSubmitted: _search,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: 'Songs, artists, albums...',
            hintStyle: TextStyle(
              color: AurumTheme.textMutedOf(context),
              fontSize: 14,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: AurumTheme.textMutedOf(context),
              size: 20,
            ),
            suffixIcon: _controller.text.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      _controller.clear();
                      setState(() {
                        _results = [];
                        _suggestions = [];
                        _showSuggestions = false;
                      });
                    },
                    child: Icon(
                      Icons.close_rounded,
                      color: AurumTheme.textMutedOf(context),
                      size: 18,
                    ),
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

  Widget _buildSuggestions(BuildContext context) {
    return ListView.builder(
      itemCount: _suggestions.length,
      itemBuilder: (_, i) {
        return ListTile(
          leading: Icon(
            Icons.search_rounded,
            color: AurumTheme.textMutedOf(context),
            size: 18,
          ),
          title: Text(
            _suggestions[i],
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 14,
            ),
          ),
          trailing: Icon(
            Icons.north_west_rounded,
            color: AurumTheme.textMutedOf(context),
            size: 16,
          ),
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

  Widget _buildEmpty(BuildContext context) {
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
          Text(
            'Search for your favourite songs',
            style: TextStyle(
              color: AurumTheme.textMutedOf(context),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
