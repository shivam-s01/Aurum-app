import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/song.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_loader.dart';
import '../utils/constants.dart';

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
  List<String> _history = [];
  bool _loading = false;
  bool _showSuggestions = false;
  bool _focused = false;

  Timer? _debounce;
  Timer? _suggestDebounce;

  // Trending chips — static for now, can be fetched from API
  static const _trending = [
    'Arijit Singh', 'AP Dhillon', 'Diljit Dosanjh',
    'Pritam', 'Shankar Ehsaan Loy', 'AR Rahman',
  ];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _focusNode.addListener(() {
      setState(() => _focused = _focusNode.hasFocus);
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

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.keySearchHistory);
      if (raw != null) {
        setState(() => _history =
            List<String>.from(jsonDecode(raw)));
      }
    } catch (_) {}
  }

  Future<void> _saveHistory(String query) async {
    _history.remove(query);
    _history.insert(0, query);
    if (_history.length > AppConstants.searchHistoryLimit) {
      _history = _history.sublist(
          0, AppConstants.searchHistoryLimit);
    }
    setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          AppConstants.keySearchHistory,
          jsonEncode(_history));
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    setState(() => _history = []);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.keySearchHistory);
    } catch (_) {}
  }

  void _onChanged(String q) {
    _suggestDebounce?.cancel();
    setState(() {});
    if (q.trim().isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }
    _suggestDebounce =
        Timer(const Duration(milliseconds: 280), () async {
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
    _saveHistory(q.trim());
    setState(() {
      _loading = true;
      _showSuggestions = false;
      _results = [];
    });
    _debounce =
        Timer(const Duration(milliseconds: 150), () async {
      final results = await ApiService.search(q);
      if (mounted) {
        setState(() {
          _results = results;
          _loading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            _buildSearchBar(context),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: ShaderMask(
        shaderCallback: (b) =>
            AurumTheme.goldGradient.createShader(b),
        child: const Text(
          'Search',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _focused
                ? AurumTheme.gold.withOpacity(0.5)
                : AurumTheme.dividerOf(context),
            width: _focused ? 1 : 0.5,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: AurumTheme.gold
                        .withOpacity(0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  )
                ]
              : [],
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
              color: _focused
                  ? AurumTheme.gold
                  : AurumTheme.textMutedOf(context),
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
                      color:
                          AurumTheme.textMutedOf(context),
                      size: 18,
                    ),
                  )
                : null,
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 14),
          ),
          textInputAction: TextInputAction.search,
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_showSuggestions) return _buildSuggestions(context);
    if (_loading) return const AurumLoaderScreen();
    if (_results.isNotEmpty) return _buildResults();

    // Empty state: show history + trending
    return _buildDiscovery(context);
  }

  Widget _buildSuggestions(BuildContext context) {
    return ListView.builder(
      itemCount: _suggestions.length,
      padding: const EdgeInsets.only(top: 4),
      itemBuilder: (_, i) => ListTile(
        leading: Icon(Icons.search_rounded,
            color: AurumTheme.textMutedOf(context),
            size: 18),
        title: Text(
          _suggestions[i],
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 14,
          ),
        ),
        trailing: Icon(Icons.north_west_rounded,
            color: AurumTheme.textMutedOf(context),
            size: 15),
        dense: true,
        onTap: () {
          _controller.text = _suggestions[i];
          _search(_suggestions[i]);
        },
      ),
    );
  }

  Widget _buildResults() {
    return ListView.builder(
      itemCount: _results.length,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 80),
      itemBuilder: (_, i) => SongTile(
        song: _results[i],
        queue: _results,
        index: i,
      ),
    );
  }

  Widget _buildDiscovery(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search History
          if (_history.isNotEmpty) ...[
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(20, 20, 16, 12),
              child: Row(
                children: [
                  Text(
                    'Recent Searches',
                    style: TextStyle(
                      color:
                          AurumTheme.textPrimaryOf(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _clearHistory,
                    child: Text(
                      'Clear',
                      style: TextStyle(
                        color: AurumTheme.gold
                            .withOpacity(0.7),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ..._history.take(6).map(
                  (q) => ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 0),
                    leading: Icon(Icons.history_rounded,
                        color: AurumTheme.textMutedOf(
                            context),
                        size: 18),
                    title: Text(
                      q,
                      style: TextStyle(
                        color:
                            AurumTheme.textPrimaryOf(
                                context),
                        fontSize: 14,
                      ),
                    ),
                    trailing: GestureDetector(
                      onTap: () {
                        setState(
                            () => _history.remove(q));
                        _saveHistory(''); // trigger save
                      },
                      child: Icon(Icons.close_rounded,
                          color: AurumTheme.textMutedOf(
                              context),
                          size: 16),
                    ),
                    dense: true,
                    onTap: () {
                      _controller.text = q;
                      _search(q);
                    },
                  ),
                ),
          ],

          // Trending
          Padding(
            padding:
                const EdgeInsets.fromLTRB(20, 24, 16, 12),
            child: Text(
              '🔥 Trending Artists',
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _trending
                  .map((t) => _TrendingChip(
                        label: t,
                        onTap: () {
                          _controller.text = t;
                          _search(t);
                        },
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendingChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TrendingChip(
      {required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AurumTheme.dividerOf(context),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: AurumTheme.textSecondaryOf(context),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
