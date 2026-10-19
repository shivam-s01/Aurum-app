// ═══════════════════════════════════════════════════════════════════════════
// FILE: lib/screens/jam_screen.dart
// DESCRIPTION: "Astra Jam" page — start a room, join by code/link, and the
//   live room view (members, now playing, sync nudge).
//
// LIGHTWEIGHT BY DESIGN: no images except member avatars (cached network
// image, tiny), no blur / shader effects, no per-frame animation. The page
// rebuilds only when JamService notifies (join/leave/status changes — a
// handful of times per minute), and now-playing is read with a Selector so
// position ticks never rebuild it.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/jam_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_pressable.dart';

/// Tiny two-language string table (Hindi when the app language is Hindi,
/// English otherwise) — keeps the Jam page self-contained so it needs no
/// changes to the 20 .arb files.
class _S {
  final bool hi;
  const _S(this.hi);
  static _S of(BuildContext c) => _S(Localizations.localeOf(c).languageCode == 'hi');
  String t(String en, String h) => hi ? h : en;

  String get title => 'Astra Jam';
  String get tagline => t('Listen together, in perfect sync.', 'Doston ke saath ek hi gaana, ek hi time pe.');
  String get roomNameHint => t('Room name (optional)', 'Room ka naam (optional)');
  String get start => t('Start a Jam', 'Jam shuru karo');
  String get or => t('or', 'ya');
  String get joinWithCode => t('Join with a code', 'Code se join karo');
  String get join => t('Join', 'Join karo');
  String get codeHint => t('6-character code', '6 akshar ka code');
  String get how => t('How it works', 'Kaise kaam karta hai');
  String get how1 => t('Start a Jam and give it a name', 'Jam shuru karo aur naam do');
  String get how2 => t('Share the link or code with friends', 'Link ya code doston ko bhejo');
  String get how3 => t('Play any song — everyone hears it together', 'Koi bhi gaana chalao, sabko saath sunai dega');
  String get connecting => t('Connecting…', 'Connect ho raha hai…');
  String get hostedBy => t('Hosted by', 'Host');
  String get nowPlaying => t('Now playing', 'Abhi chal raha hai');
  String get nothingYet => t('Nothing playing yet', 'Abhi kuch nahi chal raha');
  String get hostHint => t('Play any song from Astra — everyone in the room will hear it.',
      'Astra se koi bhi gaana chalao — room me sabko sunai dega.');
  String get guestHint => t('The host controls the music. It starts together for everyone.',
      'Gaana host chalata hai. Sabke liye ek saath shuru hota hai.');
  String get people => t('In this Jam', 'Is Jam me');
  String get host => t('Host', 'Host');
  String get you => t('You', 'Aap');
  String get ok => t('In sync', 'Sync me');
  String get buffering => t('Buffering', 'Buffer ho raha hai');
  String get syncing => t('Syncing', 'Sync ho raha hai');
  String get share => t('Invite friends', 'Doston ko bulao');
  String get copyCode => t('Code copied', 'Code copy ho gaya');
  String get leave => t('Leave Jam', 'Jam chhodo');
  String get end => t('Leave', 'Chhodo');
  String get leaveTitle => t('Leave this Jam?', 'Jam chhodna hai?');
  String get leaveBody => t('The music keeps playing on your phone, but no longer in sync.',
      'Gaana aapke phone pe chalta rahega, par sync me nahi.');
  String get cancel => t('Cancel', 'Cancel');
  String get fineTune => t('Fine-tune sync', 'Sync theek karo');
  String get fineTuneHint => t('Using Bluetooth earbuds and hearing a delay? Nudge it here.',
      'Bluetooth earbuds me delay lag raha hai? Yahan se theek karo.');
  String get roomFull => t('This Jam is full (max 4 people).', 'Ye Jam full hai (max 4 log).');
  String get preview => t('You\u2019re invited', 'Aapko bulaya gaya hai');
  String get inRoom => t('in the room', 'room me');
  String get pauseAll => t('Pause for everyone', 'Sabke liye pause');
  String get playAll => t('Play for everyone', 'Sabke liye play');

  String notice(JamNotice n) {
    switch (n) {
      case JamNotice.roomNotFound:
        return t('Room not found. Check the code and try again.', 'Room nahi mila. Code check karke dobara try karo.');
      case JamNotice.roomFull:
        return roomFull;
      case JamNotice.connectionFailed:
        return t('Couldn\u2019t connect. Check your internet.', 'Connect nahi ho paya. Internet check karo.');
      case JamNotice.localSongSkipped:
        return t('Songs stored on your phone can\u2019t be shared in a Jam.',
            'Phone me saved gaane Jam me share nahi ho sakte.');
      case JamNotice.youAreHostNow:
        return t('The host left — you\u2019re the host now.', 'Host chala gaya \u2014 ab aap host ho.');
      case JamNotice.waitingForFriend:
        return t('A friend\u2019s internet is slow — waiting a moment…', 'Kisi dost ka net slow hai \u2014 thoda ruk rahe hain…');
      case JamNotice.reconnecting:
        return t('Reconnecting…', 'Dobara connect ho raha hai…');
      case JamNotice.hostEnded:
        return t('This Jam has ended.', 'Ye Jam khatam ho gaya.');
      case JamNotice.none:
        return '';
    }
  }

  String status(String s) => s == 'buffering' ? buffering : (s == 'syncing' ? syncing : ok);
}

class JamScreen extends StatefulWidget {
  /// When opened from a link / deep link the code is passed here.
  final String? initialCode;
  const JamScreen({super.key, this.initialCode});

  @override
  State<JamScreen> createState() => _JamScreenState();
}

class _JamScreenState extends State<JamScreen> {
  final _jam = JamService.instance;
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _jam.attach(context.read<PlayerProvider>());
    _jam.addListener(_onJam);
    final code = widget.initialCode;
    if (code != null && code.isNotEmpty) {
      _codeCtrl.text = JamService.parseCode(code) ?? '';
      // Only auto-peek if we're not already inside a room.
      if (!_jam.inRoom) WidgetsBinding.instance.addPostFrameCallback((_) => _peek());
    }
  }

  @override
  void dispose() {
    _jam.removeListener(_onJam);
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _onJam() {
    if (!mounted) return;
    final n = _jam.notice;
    if (n != JamNotice.none) {
      final msg = _S.of(context).notice(n);
      // "waiting" / "reconnecting" are shown as a live banner in the room;
      // everything else is a one-time toast.
      if (n != JamNotice.waitingForFriend && n != JamNotice.reconnecting) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(msg),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ));
        _jam.clearNotice();
      }
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    await _jam.createRoom(_nameCtrl.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _peek() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    await _jam.peek(_codeCtrl.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _confirmLeave() async {
    final s = _S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(s.leaveTitle),
        content: Text(s.leaveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.cancel)),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(s.end)),
        ],
      ),
    );
    if (ok == true) await _jam.leave();
  }

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: AurumTheme.textPrimaryOf(context)),
        title: Text(
          s.title,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _jam,
          builder: (context, _) {
            switch (_jam.phase) {
              case JamPhase.connecting:
                return _Centered(text: s.connecting);
              case JamPhase.previewing:
                return _PreviewView(onJoin: () => _jam.join(), onCancel: () => _jam.leave());
              case JamPhase.inRoom:
                return _RoomView(onLeave: _confirmLeave);
              case JamPhase.idle:
                return _HomeView(
                  nameCtrl: _nameCtrl,
                  codeCtrl: _codeCtrl,
                  busy: _busy,
                  onStart: _start,
                  onJoin: _peek,
                );
            }
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────
class _Centered extends StatelessWidget {
  final String text;
  const _Centered({required this.text});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AurumTheme.accentOf(context)),
        ),
        const SizedBox(height: 16),
        Text(text, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 14)),
      ]),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool busy;
  const _PrimaryButton({required this.label, this.icon, this.onTap, this.busy = false});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final fg = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
    return AurumPressable(
      onTap: busy ? null : onTap,
      child: Container(
        height: 54,
        width: double.infinity,
        decoration: BoxDecoration(
          color: onTap == null ? accent.withOpacity(0.4) : accent,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: busy
            ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: fg))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, color: fg, size: 20), const SizedBox(width: 8)],
                Text(label, style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w700)),
              ]),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: child,
    );
  }
}

InputDecoration _fieldDecoration(BuildContext context, String hint, {String? prefix}) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: AurumTheme.dividerOf(context)),
  );
  return InputDecoration(
    hintText: hint,
    prefixText: prefix,
    prefixStyle: TextStyle(
      color: AurumTheme.accentOf(context),
      fontWeight: FontWeight.w800,
      letterSpacing: 1.2,
      fontSize: 16,
    ),
    hintStyle: TextStyle(color: AurumTheme.textMutedOf(context)),
    counterText: '',
    filled: true,
    fillColor: AurumTheme.bgCardOf(context),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: border,
    enabledBorder: border,
    focusedBorder: border.copyWith(borderSide: BorderSide(color: AurumTheme.accentOf(context), width: 1.4)),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// 1) Home — start or join
// ─────────────────────────────────────────────────────────────────────────
class _HomeView extends StatelessWidget {
  final TextEditingController nameCtrl;
  final TextEditingController codeCtrl;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onJoin;
  const _HomeView({
    required this.nameCtrl,
    required this.codeCtrl,
    required this.busy,
    required this.onStart,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final accent = AurumTheme.accentOf(context);
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: accent.withOpacity(0.16), borderRadius: BorderRadius.circular(16)),
            child: Icon(Icons.groups_rounded, color: accent, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(s.tagline, style: TextStyle(color: ts, fontSize: 15, height: 1.35)),
          ),
        ]),
        const SizedBox(height: 22),
        TextField(
          controller: nameCtrl,
          maxLength: 24,
          textCapitalization: TextCapitalization.words,
          style: TextStyle(color: tp, fontSize: 16),
          decoration: _fieldDecoration(context, s.roomNameHint),
        ),
        const SizedBox(height: 12),
        _PrimaryButton(label: s.start, icon: Icons.play_arrow_rounded, onTap: onStart, busy: busy),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(child: Divider(color: AurumTheme.dividerOf(context))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(s.or, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
          ),
          Expanded(child: Divider(color: AurumTheme.dividerOf(context))),
        ]),
        const SizedBox(height: 22),
        Text(s.joinWithCode, style: TextStyle(color: tp, fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        TextField(
          controller: codeCtrl,
          maxLength: 20,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(color: tp, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2),
          decoration: _fieldDecoration(context, s.codeHint, prefix: JamService.codePrefix),
          onSubmitted: (_) => onJoin(),
        ),
        const SizedBox(height: 12),
        _PrimaryButton(label: s.join, icon: Icons.login_rounded, onTap: onJoin),
        const SizedBox(height: 26),
        _Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.how, style: TextStyle(color: tp, fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _Step(n: 1, text: s.how1),
            _Step(n: 2, text: s.how2),
            _Step(n: 3, text: s.how3),
          ]),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String text;
  const _Step({required this.n, required this.text});
  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: accent.withOpacity(0.18), shape: BoxShape.circle),
          child: Text('$n', style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 14, height: 1.3)),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 2) Join preview (opened from a link or after typing a code)
// ─────────────────────────────────────────────────────────────────────────
class _PreviewView extends StatelessWidget {
  final VoidCallback onJoin;
  final VoidCallback onCancel;
  const _PreviewView({required this.onJoin, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Text(s.preview, style: TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
        const SizedBox(height: 8),
        Text(
          jam.previewRoomName.isEmpty ? s.title : jam.previewRoomName,
          style: TextStyle(color: tp, fontSize: 28, fontWeight: FontWeight.w800, height: 1.15),
        ),
        const SizedBox(height: 6),
        Text('${s.hostedBy} ${jam.previewHostName}', style: TextStyle(color: ts, fontSize: 14)),
        const SizedBox(height: 20),
        _Card(
          child: Row(children: [
            Icon(Icons.music_note_rounded, color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                jam.previewSong.isEmpty ? s.nothingYet : jam.previewSong,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tp, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Text('${jam.previewCount}/${JamService.maxMembers} ${s.inRoom}', style: TextStyle(color: ts, fontSize: 13)),
        const SizedBox(height: 24),
        _PrimaryButton(label: s.join, icon: Icons.login_rounded, onTap: onJoin),
        const SizedBox(height: 10),
        TextButton(
          onPressed: onCancel,
          child: Text(s.cancel, style: TextStyle(color: ts)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 3) Live room
// ─────────────────────────────────────────────────────────────────────────
class _RoomView extends StatelessWidget {
  final VoidCallback onLeave;
  const _RoomView({required this.onLeave});

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        Text(
          jam.roomName.isEmpty ? s.title : jam.roomName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: tp, fontSize: 28, fontWeight: FontWeight.w800, height: 1.15),
        ),
        const SizedBox(height: 14),

        // Code + share
        _Card(
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('CODE', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(jam.fullCode, style: TextStyle(color: accent, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
              ]),
            ),
            IconButton(
              tooltip: s.copyCode,
              icon: Icon(Icons.copy_rounded, color: ts),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: jam.fullCode));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text(s.copyCode),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ));
              },
            ),
          ]),
        ),
        const SizedBox(height: 10),
        _PrimaryButton(
          label: s.share,
          icon: Icons.ios_share_rounded,
          onTap: () {
            final text = '${jam.roomName.isEmpty ? 'Astra Jam' : jam.roomName} \u2014 Astra Jam\n'
                'Code: ${jam.fullCode}\n${jam.shareLink}';
            Share.share(text);
          },
        ),

        if (jam.notice == JamNotice.waitingForFriend || jam.notice == JamNotice.reconnecting) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: accent.withOpacity(0.14), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
              const SizedBox(width: 12),
              Expanded(child: Text(s.notice(jam.notice), style: TextStyle(color: tp, fontSize: 13.5))),
            ]),
          ),
        ],

        const SizedBox(height: 22),
        Text(s.nowPlaying, style: TextStyle(color: ts, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
        const SizedBox(height: 10),
        const _NowPlayingCard(),
        const SizedBox(height: 8),
        Text(jam.isHost ? s.hostHint : s.guestHint, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12.5, height: 1.35)),

        const SizedBox(height: 22),
        Text('${s.people}  \u2022  ${jam.members.length}/${JamService.maxMembers}',
            style: TextStyle(color: ts, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
        const SizedBox(height: 10),
        _MemberGrid(members: jam.members, myId: jam.myId),

        const SizedBox(height: 22),
        _NudgeCard(),

        const SizedBox(height: 22),
        Center(
          child: TextButton.icon(
            onPressed: onLeave,
            icon: const Icon(Icons.logout_rounded, size: 18, color: Color(0xFFE5645A)),
            label: Text(s.leave, style: const TextStyle(color: Color(0xFFE5645A), fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard();

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    // Selectors: only song identity + play state rebuild this card, never
    // the 4×/second position updates.
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);
    final playing = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);

    return _Card(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 56,
            height: 56,
            child: (song == null || song.artworkUrl.isEmpty)
                ? Container(color: accent.withOpacity(0.16), child: Icon(Icons.music_note_rounded, color: accent))
                : CachedNetworkImage(
                    imageUrl: song.artworkUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 112,
                    placeholder: (_, __) => Container(color: accent.withOpacity(0.12)),
                    errorWidget: (_, __, ___) => Container(color: accent.withOpacity(0.16), child: Icon(Icons.music_note_rounded, color: accent)),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              song?.title ?? s.nothingYet,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tp, fontSize: 15.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              song?.artist ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: ts, fontSize: 13),
            ),
          ]),
        ),
        if (jam.isHost && song != null)
          AurumPressable(
            onTap: () => playing ? jam.hostPause() : jam.hostResume(),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black,
                size: 28,
                semanticLabel: playing ? s.pauseAll : s.playAll,
              ),
            ),
          ),
      ]),
    );
  }
}


// Video-call style member tiles: 1 person = full width, 2+ = two per row.
// Big round DP with a status ring (green = in sync, amber = syncing).
class _MemberGrid extends StatelessWidget {
  final List<JamMember> members;
  final String? myId;
  const _MemberGrid({required this.members, required this.myId});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 10.0;
      final single = members.length == 1;
      final w = single ? c.maxWidth : (c.maxWidth - gap) / 2;
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final m in members)
            SizedBox(width: w, child: _MemberTile(m: m, isMe: m.id == myId)),
        ],
      );
    });
  }
}

class _MemberTile extends StatelessWidget {
  final JamMember m;
  final bool isMe;
  const _MemberTile({required this.m, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);
    final ring = m.status == 'ok' ? const Color(0xFF4CC38A) : const Color(0xFFE0A63A);
    final initial = m.name.isEmpty ? '?' : String.fromCharCode(m.name.runes.first).toUpperCase();

    return Container(
      height: 178,
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 12),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 2.5)),
            child: ClipOval(
              child: (m.avatar != null && m.avatar!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: m.avatar!,
                      fit: BoxFit.cover,
                      memCacheWidth: 176,
                      errorWidget: (_, __, ___) => _Initial(initial: initial, color: accent),
                      placeholder: (_, __) => _Initial(initial: initial, color: accent),
                    )
                  : _Initial(initial: initial, color: accent),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isMe ? '${m.name} (${s.you})' : m.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: tp, fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          if (m.isHost)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: accent.withOpacity(0.18), borderRadius: BorderRadius.circular(8)),
              child: Text(s.host, style: TextStyle(color: accent, fontSize: 10.5, fontWeight: FontWeight.w800)),
            )
          else
            Text(s.status(m.status), style: TextStyle(color: ts, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  final String initial;
  final Color color;
  const _Initial({required this.initial, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        color: color.withOpacity(0.2),
        alignment: Alignment.center,
        child: Text(initial, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 16)),
      );
}

class _NudgeCard extends StatefulWidget {
  @override
  State<_NudgeCard> createState() => _NudgeCardState();
}

class _NudgeCardState extends State<_NudgeCard> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);
    final v = _drag ?? jam.nudgeMs.toDouble();

    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(s.fineTune, style: TextStyle(color: tp, fontSize: 15, fontWeight: FontWeight.w700))),
          Text('${v >= 0 ? '+' : ''}${v.round()} ms', style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        Text(s.fineTuneHint, style: TextStyle(color: ts, fontSize: 12.5, height: 1.3)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: accent,
            thumbColor: accent,
            inactiveTrackColor: accent.withOpacity(0.2),
            overlayColor: accent.withOpacity(0.12),
            trackHeight: 3,
          ),
          child: Slider(
            min: -300,
            max: 300,
            divisions: 60,
            value: v.clamp(-300.0, 300.0).toDouble(),
            onChanged: (x) => setState(() => _drag = x),
            onChangeEnd: (x) {
              jam.setNudge(x.round());
              setState(() => _drag = null);
            },
          ),
        ),
      ]),
    );
  }
}
