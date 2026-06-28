import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../theme/aurum_theme.dart';

class ChangelogSheet extends StatefulWidget {
  const ChangelogSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ChangelogSheet(),
    );
  }

  @override
  State<ChangelogSheet> createState() => _ChangelogSheetState();
}

class _ChangelogSheetState extends State<ChangelogSheet> {
  List<_Release> _releases = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await http.get(
        Uri.parse('https://api.github.com/repos/shivam-s01/Aurum-app/releases'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        setState(() {
          _releases = data.map((r) => _Release(
            tag: r['tag_name'] ?? '',
            name: r['name'] ?? r['tag_name'] ?? '',
            body: r['body'] ?? '',
            date: r['published_at'] ?? '',
            isLatest: data.indexOf(r) == 0,
          )).toList();
          _loading = false;
        });
      } else {
        setState(() { _error = 'Could not load changelog.'; _loading = false; });
      }
    } catch (_) {
      setState(() { _error = 'No internet connection.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: AurumTheme.dividerOf(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.history_rounded, color: AurumTheme.gold, size: 18),
              ),
              const SizedBox(width: 12),
              Text('Changelog',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18, fontWeight: FontWeight.w700,
                )),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close_rounded, color: AurumTheme.textMutedOf(context)),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          Divider(color: AurumTheme.dividerOf(context), height: 1),
          // Body
          Expanded(
            child: _loading
              ? Center(child: CircularProgressIndicator(color: AurumTheme.gold, strokeWidth: 2))
              : _error != null
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.cloud_off_rounded, color: AurumTheme.textMutedOf(context), size: 40),
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: AurumTheme.textMutedOf(context))),
                    const SizedBox(height: 16),
                    TextButton(onPressed: () { setState(() { _loading = true; _error = null; }); _load(); },
                      child: const Text('Retry', style: TextStyle(color: AurumTheme.gold))),
                  ]))
                : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    controller: ctrl,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                    itemCount: _releases.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _ReleaseCard(release: _releases[i]),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _Release {
  final String tag, name, body, date;
  final bool isLatest;
  const _Release({required this.tag, required this.name, required this.body, required this.date, required this.isLatest});

  String get formattedDate {
    if (date.isEmpty) return '';
    try {
      final d = DateTime.parse(date);
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[d.month - 1]} ${d.day}, ${d.year}';
    } catch (_) { return ''; }
  }
}

class _ReleaseCard extends StatefulWidget {
  final _Release release;
  const _ReleaseCard({required this.release});
  @override
  State<_ReleaseCard> createState() => _ReleaseCardState();
}

class _ReleaseCardState extends State<_ReleaseCard> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.release.isLatest;
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); setState(() => _expanded = !_expanded); },
      child: Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: r.isLatest
              ? AurumTheme.gold.withOpacity(0.4)
              : AurumTheme.dividerOf(context),
            width: r.isLatest ? 1 : 0.5,
          ),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(r.name.isEmpty ? r.tag : r.name,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 14, fontWeight: FontWeight.w700,
                    )),
                  if (r.isLatest) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AurumTheme.gold.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AurumTheme.gold.withOpacity(0.4)),
                      ),
                      child: const Text('Latest', style: TextStyle(
                        color: AurumTheme.gold, fontSize: 10, fontWeight: FontWeight.w700,
                      )),
                    ),
                  ],
                ]),
                if (r.formattedDate.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(r.formattedDate,
                    style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11)),
                ],
              ])),
              Icon(
                _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                color: AurumTheme.textMutedOf(context), size: 20,
              ),
            ]),
          ),
          if (_expanded && r.body.isNotEmpty) ...[
            Divider(color: AurumTheme.dividerOf(context), height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Text(
                r.body,
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 13, height: 1.6,
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
