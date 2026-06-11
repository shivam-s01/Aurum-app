import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
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
  final _focusNode  = FocusNode();

  List<Song>   _results     = [];
  List<String> _suggestions = [];
  List<String> _history     = [];

  bool _loading         = false;
  bool _showSuggestions = false;
  bool _showHistory     = false;

  Timer? _debounce;
  Timer? _suggestDebounce;

  static const _prefKey    = 'aurum_search_history';
  static const _maxHistory = 10;

  // ── Lifecycle ────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _controller.text.trim().isEmpty) {
        setState(() => _showHistory = _history.isNotEmpty);
      } else if (!_focusNode.hasFocus) {
        setState(() => _showHistory = false);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    super.dispose();
  }

  // ── History helpers ──────────────────────────────────────────

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _history = prefs.getStringList(_prefKey) ?? [];
      });
    }
  }

  Future<void> _saveToHistory(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _history.remove(q);
    _history.insert(0, q);
    if (_history.length > _maxHistory) _history = _history.sublist(0, _maxHistory);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefKey, _history);
    if (mounted) setState(() {});
  }

  Future<void> _removeFromHistory(String query) async {
    _history.remove(query);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefKey, _history);
    if (mounted) setState(() {});
  }

  Future<void> _clearHistory() async {
    _history.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    if (mounted) setState(() => _showHistory = false);
  }

  // ── Search logic ─────────────────────────────────────────────

  void _onChanged(String q) {
    _suggestDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _suggestions    = [];
        _showSuggestions = false;
        _showHistory    = _history.isNotEmpty && _focusNode.hasFocus;
      });
      return;
    }
    setState(() {
      _showHistory = false;
    });
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      final s = await ApiService.suggest(q);
      if (mounted && _controller.text == q) {
        setState(() {
          _suggestions    = s;
          _showSuggestions = s.isNotEmpty;
        });
      }
    });
  }

  void _search(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    HapticFeedback.lightImpact();
    FocusScope.of(context).unfocus();
    setState(() {
      _loading         = true;
      _showSuggestions = false;
      _showHistory     = false;
      _results         = [];
    });
    _saveToHistory(query);
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      final results = await ApiService.search(query);
      if (mounted) setState(() { _results = results; _loading = false; });
    });
  }

  void _clearSearch() {
    HapticFeedback.lightImpact();
    _controller.clear();
    setState(() {
      _results         = [];
      _suggestions     = [];
      _showSuggestions = false;
      _showHistory     = _history.isNotEmpty;
    });
  }

  // ── Build ────────────────────────────────────────────────────

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
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _buildBody(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_showSuggestions) return _buildSuggestions(context);
    if (_loading)         return const AurumLoaderScreen();
    if (_results.isNotEmpty) return _buildResults();
    if (_showHistory && _history.isNotEmpty) return _buildHistory(context);
    return _buildEmpty(context);
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
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Songs, artists, albums...',
            hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
            prefixIcon: Icon(Icons.search_rounded, color: AurumTheme.textMutedOf(context), size: 20),
            suffixIcon: _controller.text.isNotEmpty
                ? GestureDetector(
                    onTap: _clearSearch,
                    child: Icon(Icons.close_rounded, color: AurumTheme.textMutedOf(context), size: 18),
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

  // ── History UI ───────────────────────────────────────────────

  Widget _buildHistory(BuildContext context) {
    return Column(
      key: const ValueKey('history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent',
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              TextButton(
                onPressed: _clearHistory,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Clear all',
                  style: TextStyle(
                    color: AurumTheme.gold.withOpacity(0.8),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _history.length,
            itemBuilder: (_, i) {
              final item = _history[i];
              return ListTile(
                leading: Icon(
                  Icons.history_rounded,
                  color: AurumTheme.textMutedOf(context),
                  size: 18,
                ),
                title: Text(
                  item,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 14,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Fill search bar with this query
                    GestureDetector(
                      onTap: () {
                        _controller.text = item;
                        _controller.selection = TextSelection.fromPosition(
                          TextPosition(offset: item.length),
                        );
                        _onChanged(item);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.north_west_rounded,
                          color: AurumTheme.textMutedOf(context),
                          size: 16,
                        ),
                      ),
                    ),
                    // Remove this item
                    GestureDetector(
                      onTap: () => _removeFromHistory(item),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.close_rounded,
                          color: AurumTheme.textMutedOf(context),
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                dense: true,
                onTap: () {
                  _controller.text = item;
                  _search(item);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Suggestions UI ───────────────────────────────────────────

  Widget _buildSuggestions(BuildContext context) {
    return ListView.builder(
      key: const ValueKey('suggestions'),
      itemCount: _suggestions.length,
      itemBuilder: (_, i) {
        return ListTile(
          leading: Icon(Icons.search_rounded, color: AurumTheme.textMutedOf(context), size: 18),
          title: Text(
            _suggestions[i],
            style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14),
          ),
          trailing: Icon(Icons.north_west_rounded, color: AurumTheme.textMutedOf(context), size: 16),
          dense: true,
          onTap: () {
            _controller.text = _suggestions[i];
            _search(_suggestions[i]);
          },
        );
      },
    );
  }

  // ── Results UI ───────────────────────────────────────────────

  Widget _buildResults() {
    return ListView.builder(
      key: const ValueKey('results'),
      itemCount: _results.length,
      padding: const EdgeInsets.only(bottom: 80),
      itemBuilder: (_, i) => SongTile(
        song: _results[i],
        queue: _results,
        index: i,
      ),
    );
  }

  // ── Empty state ──────────────────────────────────────────────

  Widget _buildEmpty(BuildContext context) {
    return Center(
      key: const ValueKey('empty'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_note_rounded, color: AurumTheme.gold.withOpacity(0.2), size: 64),
          const SizedBox(height: 16),
          Text(
            'Search for your favourite songs',
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
          ),
        ],
      ),
    );
  }
}
