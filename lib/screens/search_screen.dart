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

  // Full ("submit") search results — Saavn + YouTube merged.
  List<Song>   _results     = [];

  // Live-as-you-type results — fast Saavn-only quick search.
  List<Song>   _liveResults = [];

  // Text autocomplete suggestions.
  List<String> _suggestions = [];

  List<String> _history     = [];

  bool _loading     = false; // full search in progress (after Enter)
  bool _liveLoading = false; // live search in progress (while typing)
  bool _showHistory = false;

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

  // Fires on every keystroke. Debounced, then fetches BOTH text
  // suggestions and fast "live" song results in parallel — so the
  // user sees real, tappable songs while still typing (Fabtune-style),
  // not just a list of search terms.
  void _onChanged(String q) {
    _suggestDebounce?.cancel();
    final query = q.trim();

    if (query.isEmpty) {
      setState(() {
        _suggestions  = [];
        _liveResults  = [];
        _liveLoading  = false;
        _showHistory  = _history.isNotEmpty && _focusNode.hasFocus;
      });
      return;
    }

    setState(() {
      _showHistory = false;
      _liveLoading = true;
    });

    _suggestDebounce = Timer(const Duration(milliseconds: 280), () async {
      if (!mounted || _controller.text.trim() != query) return;

      final fetched = await Future.wait([
        ApiService.suggest(query),
        ApiService.quickSearch(query),
      ]);

      if (!mounted || _controller.text.trim() != query) return;

      setState(() {
        _suggestions = fetched[0] as List<String>;
        _liveResults = fetched[1] as List<Song>;
        _liveLoading = false;
      });
    });
  }

  // Full search — Saavn + YouTube merged. Triggered on Enter/submit,
  // tapping a text suggestion, a history item, or "See all results".
  void _search(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    HapticFeedback.lightImpact();
    FocusScope.of(context).unfocus();
    setState(() {
      _loading     = true;
      _liveLoading = false;
      _showHistory = false;
      _results     = [];
    });
    _saveToHistory(query);
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final results = await ApiService.search(query);
      if (mounted) setState(() { _results = results; _loading = false; });
    });
  }

  void _clearSearch() {
    HapticFeedback.lightImpact();
    _suggestDebounce?.cancel();
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _results      = [];
      _liveResults  = [];
      _suggestions  = [];
      _liveLoading  = false;
      _loading      = false;
      _showHistory  = _history.isNotEmpty;
    });
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
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
    if (_loading) return const AurumLoaderScreen(key: ValueKey('loading'));
    if (_results.isNotEmpty) return _buildResults();
    if (_controller.text.trim().isNotEmpty) return _buildLivePanel(context);
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

  // ── Live search panel (suggestions + live song results) ───────

  Widget _buildLivePanel(BuildContext context) {
    final query         = _controller.text.trim();
    final hasSuggestions = _suggestions.isNotEmpty;
    final hasLive        = _liveResults.isNotEmpty;

    Widget content;
    if (!hasSuggestions && !hasLive) {
      content = _liveLoading
          ? _buildLiveLoadingState(context)
          : _buildNoLiveResults(context, query);
    } else {
      content = ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          if (_liveLoading) _buildLiveProgressBar(context),
          if (hasSuggestions) ...[
            ..._suggestions.map((s) => _suggestionTile(context, s)),
            if (hasLive)
              Divider(
                color: AurumTheme.dividerOf(context),
                height: 1,
                indent: 16,
                endIndent: 16,
              ),
          ],
          if (hasLive) ...[
            _sectionLabel(context, 'Songs'),
            ..._liveResults.asMap().entries.map(
                  (e) => SongTile(
                    key: ValueKey('live_${e.value.id}_${e.key}'),
                    song: e.value,
                    queue: _liveResults,
                    index: e.key,
                  ),
                ),
          ],
          if (query.isNotEmpty) _seeAllTile(context, query),
        ],
      );
    }

    // Tapping anywhere (e.g. a song result) immediately drops focus so the
    // keyboard closes and no further debounced live-search calls fire
    // mid-tap — this is what made taps feel "stuck" before.
    return Listener(
      key: const ValueKey('live'),
      onPointerDown: (_) {
        if (_focusNode.hasFocus) {
          _suggestDebounce?.cancel();
          FocusScope.of(context).unfocus();
        }
      },
      child: content,
    );
  }

  Widget _buildLiveProgressBar(BuildContext context) {
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        backgroundColor: Colors.transparent,
        valueColor: AlwaysStoppedAnimation<Color>(AurumTheme.gold.withOpacity(0.7)),
      ),
    );
  }

  Widget _buildLiveLoadingState(BuildContext context) {
    return Column(
      children: [
        _buildLiveProgressBar(context),
        const Expanded(
          child: Center(
            child: AurumLoaderSmall(),
          ),
        ),
      ],
    );
  }

  Widget _buildNoLiveResults(BuildContext context, String query) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, color: AurumTheme.gold.withOpacity(0.2), size: 56),
          const SizedBox(height: 12),
          Text(
            'No results for "$query"',
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => _search(query),
            child: Text(
              'Search everywhere',
              style: TextStyle(color: AurumTheme.gold, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: AurumTheme.textMutedOf(context),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      ),
    );
  }

  Widget _suggestionTile(BuildContext context, String s) {
    return ListTile(
      key: ValueKey('sugg_$s'),
      leading: Icon(Icons.search_rounded, color: AurumTheme.textMutedOf(context), size: 18),
      title: Text(
        s,
        style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _controller.text = s;
          _controller.selection = TextSelection.fromPosition(TextPosition(offset: s.length));
          _onChanged(s);
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.north_west_rounded, color: AurumTheme.textMutedOf(context), size: 16),
        ),
      ),
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      onTap: () {
        _controller.text = s;
        _search(s);
      },
    );
  }

  Widget _seeAllTile(BuildContext context, String query) {
    return ListTile(
      key: const ValueKey('see_all'),
      leading: Icon(Icons.travel_explore_rounded, color: AurumTheme.gold, size: 20),
      title: Text(
        'See all results for "$query"',
        style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(Icons.arrow_forward_ios_rounded, color: AurumTheme.gold.withOpacity(0.6), size: 14),
      dense: true,
      onTap: () => _search(query),
    );
  }

  // ── Results UI ───────────────────────────────────────────────

  Widget _buildResults() {
    return ListView.builder(
      key: const ValueKey('results'),
      itemCount: _results.length,
      padding: const EdgeInsets.only(bottom: 80),
      itemBuilder: (_, i) => SongTile(
        key: ValueKey('result_${_results[i].id}_$i'),
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
