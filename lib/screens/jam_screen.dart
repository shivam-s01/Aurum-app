// ═══════════════════════════════════════════════════════════════════════════
// FILE: lib/screens/jam_screen.dart
// DESCRIPTION: "Astra Jam" page — start a room, join by code/link, and the
//   live room view (members, now playing, invite, sync nudge).
//
// LIGHTWEIGHT BY DESIGN: no blur / shader effects, no per-frame animation
// in the room. Only member avatars + now-playing artwork are images (cached,
// tiny). The page rebuilds only when JamService notifies, and now-playing is
// read with a Selector so position ticks never rebuild it. All motion goes
// through AurumMotion (respects "Enable Animations" + Battery Saver) and all
// feedback through AurumHaptics (respects the user's haptic intensity).
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../services/jam_service.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_transitions.dart' show AurumPageRoute;
import '../widgets/aurum_pressable.dart';
import 'jam_settings_screen.dart';

const Color _kGreen = Color(0xFF4CC38A);
const Color _kAmber = Color(0xFFE0A63A);
const Color _kRed = Color(0xFFE5645A);

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
  String get newRoom => t('Create a room', 'Naya room banao');
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
  String get slowNet => t('Taking longer than usual. Check your internet.', 'Thoda zyada time lag raha hai. Internet check karo.');
  String get hostedBy => t('Hosted by', 'Host');
  String get nowPlaying => t('Now playing', 'Abhi chal raha hai');
  String get nothingYet => t('Nothing playing yet', 'Abhi kuch nahi chal raha');
  String get hostHint => t('Play any song from Astra \u2014 everyone hears it. Pause or play here, and it happens for everyone.',
      'Astra se koi bhi gaana chalao \u2014 sabko sunai dega. Yahan pause ya play karoge to sabke liye hoga.');
  String get guestHint => t('The host controls the music \u2014 when the host pauses or plays, it happens for everyone.',
      'Gaana host chalata hai \u2014 host pause ya play karega to sabke liye hoga.');
  String get people => t('In this Jam', 'Is Jam me');
  String get host => t('Host', 'Host');
  String get you => t('You', 'Aap');
  String get ok => t('In sync', 'Sync me');
  String get buffering => t('Buffering', 'Buffer ho raha hai');
  String get reconnectingChip => t('Reconnecting', 'Dobara connect');
  String get liveSynced => t('In sync right now (within 35 ms)', 'Abhi sync me hai (35 ms ke andar)');
  String liveOff(int ms) => ms > 0
      ? t('You are ~$ms ms ahead of the host', 'Aap host se ~$ms ms aage ho')
      : t('You are ~${-ms} ms behind the host', 'Aap host se ~${-ms} ms peeche ho');
  String get syncing => t('Syncing', 'Sync ho raha hai');
  String get share => t('Invite', 'Bulao');
  String get inviteFriend => t('Invite a friend', 'Dost ko bulao');
  String get copy => t('Copy', 'Copy');
  String get copyCode => t('Code copied', 'Code copy ho gaya');
  String get codeLabel => t('JAM CODE', 'JAM CODE');
  String get leave => t('Leave Jam', 'Jam chhodo');
  String get end => t('Leave', 'Chhodo');
  String get leaveTitle => t('Leave this Jam?', 'Jam chhodna hai?');
  String get leaveBody => t('The music keeps playing on your phone, but no longer in sync.',
      'Gaana aapke phone pe chalta rahega, par sync me nahi.');
  String get leaveBodyGuest => t('The music will stop on your phone when you leave.',
      'Jam chhodte hi aapke phone pe gaana ruk jayega.');
  String get cancel => t('Cancel', 'Cancel');
  String get fineTune => t('Fine-tune sync', 'Sync theek karo');
  String get fineTuneHint => t('Using Bluetooth earbuds and hearing a delay? Nudge it here.',
      'Bluetooth earbuds me delay lag raha hai? Yahan se theek karo.');
  String get roomFull => t('This Jam is full (max 4 people).', 'Ye Jam full hai (max 4 log).');
  String get preview => t('You\u2019re invited', 'Aapko bulaya gaya hai');
  String get inRoom => t('in the room', 'room me');
  String get pauseAll => t('Pause for everyone', 'Sabke liye pause');
  String get playAll => t('Play for everyone', 'Sabke liye play');
  String get retry => t('Try again', 'Dobara try karo');
  String get requesting => t('Waiting for the host\u2026', 'Host ka intezaar\u2026');
  String get requestingBody => t('The host has been asked to let you in. This usually takes a few seconds.',
      'Host ko aapki request bheji gayi hai. Kuch second lagte hain.');
  String get requestsTitle => t('Join requests', 'Join requests');
  String wantsToJoin(String n) => t('$n wants to join', '$n join karna chahta hai');
  String get approve => t('Let in', 'Andar bulao');
  String get reject => t('Decline', 'Mana karo');
  String get suggestionsTitle => t('Song suggestions', 'Gaane ke suggestions');
  String suggestedBy(String n) => t('Suggested by $n', '$n ne suggest kiya');
  String get playNext => t('Play next', 'Agla chalao');
  String get skip => t('Skip', 'Skip');
  String get makeHost => t('Make host', 'Host banao');
  String get removeMember => t('Remove from Jam', 'Jam se hatao');
  String get blockMember => t('Remove & block', 'Hatao aur block karo');
  String get collabTitle => t('Jam playlist', 'Jam playlist');
  String get collabHint => t('Every song played in this Jam collects here.',
      'Is Jam me jo bhi gaana bajega yahan jama hota rahega.');
  String get savePlaylist => t('Save as playlist', 'Playlist me save karo');
  String savedN(int n) => t('Saved $n songs to your library', '$n gaane aapki library me save ho gaye');
  String moreN(int n) => t('+$n more', '+$n aur');
  String get endForAll => t('End for everyone', 'Sabke liye khatam karo');
  String get leaveHostBody => t('The Jam continues with the next person as host.',
      'Jam agle bande ko host bana kar chalta rahega.');
  String get rejoinTitle => t('Rejoin your Jam', 'Apne Jam me wapas aao');
  String rejoinBody(String code) => t('You were in $code a moment ago.', 'Aap abhi $code me the.');
  String get rejoin => t('Rejoin', 'Wapas jao');
  String get settings => t('Jam settings', 'Jam settings');
  String get disconnectedTag => t('Reconnecting', 'Dobara connect');
  String get errorTitle => t('Couldn\u2019t open the Jam', 'Jam nahi khul paya');

  String shareMessage(String room, String code, String link) {
    final name = room.trim();
    if (hi) {
      return '\u{1F3A7} Mere Astra Jam me aao${name.isEmpty ? '' : ' \u2014 $name'}\n\n'
          'Code: $code\n$link\n\nSmooth aur optimized experience \u2014 saath me suno, ek hi time pe.';
    }
    return '\u{1F3A7} Join my Astra Jam${name.isEmpty ? '' : ' \u2014 $name'}\n\n'
        'Code: $code\n$link\n\nSmooth, optimized experience \u2014 listen together, in perfect sync.';
  }

  String notice(JamNotice n) {
    switch (n) {
      case JamNotice.roomNotFound:
        return t('Room not found. Check the code, or the host may have ended the Jam.',
            'Room nahi mila. Code check karo, ya host ne Jam band kar diya ho sakta hai.');
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
      case JamNotice.joinRejected:
        return t('The host didn\u2019t let you in.', 'Host ne aapko andar nahi aane diya.');
      case JamNotice.requestTimeout:
        return t('The host didn\u2019t answer. Try again in a moment.', 'Host ne jawab nahi diya. Thodi der baad try karo.');
      case JamNotice.kicked:
        return t('You were removed from this Jam.', 'Aapko is Jam se hata diya gaya.');
      case JamNotice.sessionExpired:
        return t('Your seat in the Jam expired. Join again with the code.',
            'Jam me aapki jagah khatam ho gayi. Code se dobara join karo.');
      case JamNotice.suggestionSent:
        return t('Suggestion sent to the host', 'Suggestion host ko bhej diya');
      case JamNotice.suggestionApproved:
        return t('The host added your song!', 'Host ne aapka gaana add kar diya!');
      case JamNotice.suggestionRejected:
        return t('The host skipped your suggestion.', 'Host ne aapka suggestion skip kar diya.');
      case JamNotice.joinRequest:
      case JamNotice.suggestionIncoming:
      case JamNotice.none:
        return '';
    }
  }

  String status(String s) => s == 'buffering' ? buffering : (s == 'syncing' ? syncing : ok);
}

enum _JamAction { none, start, join }

/// Errors that deserve a proper on-screen card (not just a toast).
bool _isBlockingError(JamNotice n) =>
    n == JamNotice.roomNotFound ||
    n == JamNotice.roomFull ||
    n == JamNotice.connectionFailed ||
    n == JamNotice.joinRejected ||
    n == JamNotice.requestTimeout;

void _shareJam(BuildContext context) {
  final s = _S.of(context);
  final jam = JamService.instance;
  Share.share(
    s.shareMessage(jam.roomName, jam.fullCode, jam.shareLink),
    subject: jam.roomName.isEmpty ? 'Astra Jam' : '${jam.roomName} \u2014 Astra Jam',
  );
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
  _JamAction _last = _JamAction.none;
  JamNotice? _error;
  JamPhase _prevPhase = JamPhase.idle;
  int _prevMembers = 0;
  String? _savedCode; // a Jam this phone can still rejoin

  @override
  void initState() {
    super.initState();
    _jam.attach(context.read<PlayerProvider>());
    _prevPhase = _jam.phase;
    _prevMembers = _jam.members.length;
    _jam.addListener(_onJam);
    _jam.loadSettings().then((_) => _jam.warmUp()); // DNS warm-up while the user is typing
    _refreshSaved();
    final code = widget.initialCode;
    if (code != null && code.isNotEmpty) {
      _codeCtrl.text = JamService.parseCode(code) ?? '';
      // Only auto-peek if we're not already inside a room.
      if (!_jam.inRoom) WidgetsBinding.instance.addPostFrameCallback((_) => _peek());
    } else if (!_jam.inRoom) {
      _fillFromClipboard();
    }
  }

  Future<void> _refreshSaved() async {
    final code = _jam.inRoom ? null : await _jam.savedSessionCode();
    if (mounted && code != _savedCode) setState(() => _savedCode = code);
  }

  Future<void> _resume() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _jam.resumeSession();
    if (mounted) {
      setState(() => _busy = false);
      _refreshSaved();
    }
  }

  /// A friend sent "ASTRA-XXXXXX" or the link → fill the code field for them.
  Future<void> _fillFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final code = JamService.extractCode(data?.text ?? '');
      if (code != null && mounted && _codeCtrl.text.trim().isEmpty) {
        setState(() => _codeCtrl.text = code);
      }
    } catch (_) {}
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

    // Haptic feedback on the moments that matter.
    final phase = _jam.phase;
    final count = _jam.members.length;
    if (phase == JamPhase.inRoom && _prevPhase != JamPhase.inRoom) {
      AurumHaptics.medium(); // you're in
    } else if (phase == JamPhase.inRoom && count > _prevMembers) {
      AurumHaptics.light(); // a friend joined
    }
    if (phase == JamPhase.idle && _prevPhase != JamPhase.idle) _refreshSaved();
    _prevPhase = phase;
    _prevMembers = count;
    if (phase != JamPhase.idle && _error != null) _error = null;

    final n = _jam.notice;
    if (n == JamNotice.none) return;

    // Cards show these inline; just a nudge so the host notices.
    if (n == JamNotice.joinRequest || n == JamNotice.suggestionIncoming) {
      AurumHaptics.medium();
      _jam.clearNotice();
      return;
    }

    if (_isBlockingError(n)) {
      // Proper error card on the home screen, with "Try again".
      AurumHaptics.vibrate();
      setState(() => _error = n);
      _jam.clearNotice();
      return;
    }

    // "waiting" / "reconnecting" are shown as a live banner in the room;
    // everything else is a one-time toast.
    if (n != JamNotice.waitingForFriend && n != JamNotice.reconnecting) {
      final msg = _S.of(context).notice(n);
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

  Future<void> _start() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _last = _JamAction.start;
      _error = null;
    });
    await _jam.createRoom(_nameCtrl.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _peek() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _last = _JamAction.join;
      _error = null;
    });
    await _jam.peek(_codeCtrl.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancelConnect() async {
    if (mounted) setState(() => _busy = false);
    await _jam.leave();
  }

  void _retry() => _last == _JamAction.start ? _start() : _peek();

  Future<void> _confirmLeave() async {
    final s = _S.of(context);
    final othersHere = _jam.members.any((m) => m.id != _jam.myId);
    // 0 = stay, 1 = leave, 2 = end for everyone (host only)
    final choice = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AurumTheme.bgElevatedOf(c),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          s.leaveTitle,
          style: TextStyle(color: AurumTheme.textPrimaryOf(c), fontWeight: FontWeight.w800, fontSize: 19),
        ),
        content: Text(
          _jam.isHost ? (othersHere ? s.leaveHostBody : s.leaveBody) : s.leaveBodyGuest,
          style: TextStyle(color: AurumTheme.textSecondaryOf(c), fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 0),
            child: Text(s.cancel, style: TextStyle(color: AurumTheme.textSecondaryOf(c))),
          ),
          if (_jam.isHost && othersHere)
            TextButton(
              onPressed: () => Navigator.pop(c, 2),
              child: Text(s.endForAll, style: const TextStyle(color: _kRed, fontWeight: FontWeight.w800)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(c, 1),
            child: Text(s.end, style: const TextStyle(color: _kRed, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (choice == 1 || choice == 2) {
      AurumHaptics.medium();
      await _jam.leave(endForAll: choice == 2);
    }
  }

  Widget _body() {
    switch (_jam.phase) {
      case JamPhase.connecting:
        return _ConnectingView(key: const ValueKey('connecting'), onCancel: _cancelConnect);
      case JamPhase.previewing:
        return _PreviewView(
          key: const ValueKey('preview'),
          onJoin: () => _jam.join(),
          onCancel: () => _jam.leave(),
        );
      case JamPhase.requesting:
        return _RequestingView(key: const ValueKey('requesting'), onCancel: () => _jam.leave());
      case JamPhase.inRoom:
        return _RoomView(key: const ValueKey('room'), onLeave: _confirmLeave);
      case JamPhase.idle:
        return _HomeView(
          key: const ValueKey('home'),
          nameCtrl: _nameCtrl,
          codeCtrl: _codeCtrl,
          busy: _busy,
          last: _last,
          error: _error,
          savedCode: _savedCode,
          onResume: _resume,
          onForgetSaved: () async {
            await _jam.forgetSavedSession();
            _refreshSaved();
          },
          onStart: _start,
          onJoin: _peek,
          onRetry: _retry,
          onDismissError: () => setState(() => _error = null),
        );
    }
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
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          IconButton(
            tooltip: s.settings,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () {
              AurumHaptics.light();
              Navigator.of(context).push(AurumPageRoute(builder: (_) => const JamSettingsScreen()));
            },
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _jam,
          builder: (context, _) {
            return AnimatedSwitcher(
              duration: AurumMotion.durationOrZero(AurumMotion.medium1),
              switchInCurve: AurumMotion.standard,
              switchOutCurve: Curves.easeIn,
              child: _body(),
            );
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────
class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool busy;
  final bool tonal;
  final double height;
  const _PrimaryButton({
    required this.label,
    this.icon,
    this.onTap,
    this.busy = false,
    this.tonal = false,
    this.height = 54,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
    final fg = tonal ? accent : onAccent;
    final enabled = onTap != null && !busy;
    final bg = tonal ? accent.withOpacity(0.16) : accent;
    return AurumPressable(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: AurumMotion.durationOrZero(AurumMotion.short2),
        opacity: (onTap == null && !busy) ? 0.45 : 1,
        child: Container(
          height: height,
          width: double.infinity,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(height / 3.4)),
          alignment: Alignment.center,
          child: busy
              ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: fg))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, color: fg, size: 20), const SizedBox(width: 8)],
                  Text(label, style: TextStyle(color: fg, fontSize: 15.5, fontWeight: FontWeight.w700)),
                ]),
        ),
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
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: child,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: AurumTheme.textSecondaryOf(context),
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      );
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
    fillColor: AurumTheme.bgOf(context),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    border: border,
    enabledBorder: border,
    focusedBorder: border.copyWith(borderSide: BorderSide(color: AurumTheme.accentOf(context), width: 1.4)),
  );
}

/// Fade + gentle scale-in, played once when the widget first appears.
/// Used for member tiles so a friend joining feels alive. Zero cost when
/// animations are off / Battery Saver is on.
class _PopIn extends StatelessWidget {
  final Widget child;
  const _PopIn({required this.child});
  @override
  Widget build(BuildContext context) {
    if (!AurumMotion.enabled) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: AurumMotion.long1,
      curve: AurumMotion.emphasized,
      child: child,
      builder: (_, t, ch) => Opacity(
        opacity: t.clamp(0.0, 1.0).toDouble(),
        child: Transform.scale(scale: 0.86 + 0.14 * t, child: ch),
      ),
    );
  }
}

/// Round avatar with optional status ring; falls back to the initial.
class _Avatar extends StatelessWidget {
  final String? url;
  final String name;
  final double size;
  final Color? ring;
  const _Avatar({required this.url, required this.name, required this.size, this.ring});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final initial = name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
    final noName = name.trim().isEmpty;
    final fallback = noName
        ? Container(color: accent.withOpacity(0.2), child: Icon(Icons.person_rounded, color: accent, size: size * 0.55))
        : _Initial(initial: initial, color: accent, fontSize: size * 0.38);
    final hasUrl = url != null && url!.isNotEmpty;
    final inner = ClipOval(
      child: hasUrl
          ? CachedNetworkImage(
              imageUrl: url!,
              fit: BoxFit.cover,
              memCacheWidth: (size * 2).round(),
              errorWidget: (_, __, ___) => fallback,
              placeholder: (_, __) => fallback,
            )
          : fallback,
    );
    if (ring == null) return SizedBox(width: size, height: size, child: inner);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring!, width: 2.5)),
      child: inner,
    );
  }
}

class _Initial extends StatelessWidget {
  final String initial;
  final Color color;
  final double fontSize;
  const _Initial({required this.initial, required this.color, this.fontSize = 16});
  @override
  Widget build(BuildContext context) => Container(
        color: color.withOpacity(0.2),
        alignment: Alignment.center,
        child: Text(initial, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: fontSize)),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// 0) Connecting — honest progress (pulse), slow-network hint, cancel
// ─────────────────────────────────────────────────────────────────────────
class _ConnectingView extends StatefulWidget {
  final VoidCallback onCancel;
  const _ConnectingView({super.key, required this.onCancel});

  @override
  State<_ConnectingView> createState() => _ConnectingViewState();
}

class _ConnectingViewState extends State<_ConnectingView> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    if (AurumMotion.enabled) _pulse.repeat(reverse: true);
    _slowTimer = Timer(const Duration(seconds: 7), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final accent = AurumTheme.accentOf(context);
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(alignment: Alignment.center, children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) {
                  final t = Curves.easeInOut.transform(_pulse.value);
                  return Container(
                    width: 84 + 36 * t,
                    height: 84 + 36 * t,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withOpacity(0.14 * (1 - t) + 0.03),
                    ),
                  );
                },
              ),
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: AurumTheme.accentGradientOf(context)),
                child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 34),
              ),
            ]),
          ),
          const SizedBox(height: 22),
          Text(s.connecting, style: TextStyle(color: tp, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          AnimatedOpacity(
            duration: AurumMotion.durationOrZero(AurumMotion.medium1),
            opacity: _slow ? 1 : 0,
            child: Text(
              s.slowNet,
              textAlign: TextAlign.center,
              style: TextStyle(color: ts, fontSize: 13.5, height: 1.4),
            ),
          ),
          const SizedBox(height: 18),
          TextButton(
            onPressed: widget.onCancel,
            child: Text(s.cancel, style: TextStyle(color: ts, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 1) Home — start or join
// ─────────────────────────────────────────────────────────────────────────
class _HomeView extends StatelessWidget {
  final TextEditingController nameCtrl;
  final TextEditingController codeCtrl;
  final bool busy;
  final _JamAction last;
  final JamNotice? error;
  final String? savedCode;
  final VoidCallback onResume;
  final VoidCallback onForgetSaved;
  final VoidCallback onStart;
  final VoidCallback onJoin;
  final VoidCallback onRetry;
  final VoidCallback onDismissError;
  const _HomeView({
    super.key,
    required this.nameCtrl,
    required this.codeCtrl,
    required this.busy,
    required this.last,
    required this.error,
    required this.savedCode,
    required this.onResume,
    required this.onForgetSaved,
    required this.onStart,
    required this.onJoin,
    required this.onRetry,
    required this.onDismissError,
  });

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final tp = AurumTheme.textPrimaryOf(context);

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Row(children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(19),
              gradient: AurumTheme.accentGradientOf(context),
            ),
            child: const Icon(Icons.groups_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(s.tagline, style: TextStyle(color: tp, fontSize: 16.5, fontWeight: FontWeight.w700, height: 1.3)),
          ),
        ]),
        const SizedBox(height: 22),

        // Inline error card (replaces the old tiny snackbar).
        AnimatedSize(
          duration: AurumMotion.durationOrZero(AurumMotion.medium1),
          curve: AurumMotion.standard,
          alignment: Alignment.topCenter,
          child: error == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _ErrorCard(notice: error!, onRetry: onRetry, onDismiss: onDismissError),
                ),
        ),

        // Rejoin a Jam we were kicked out of by a dead connection / app kill
        if (savedCode != null) ...[
          _Card(
            child: Row(children: [
              Icon(Icons.history_rounded, color: AurumTheme.accentOf(context), size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.rejoinTitle, style: TextStyle(color: tp, fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(s.rejoinBody('${JamService.codePrefix}$savedCode'),
                      style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12.5)),
                ]),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close_rounded, color: AurumTheme.textSecondaryOf(context), size: 18),
                onPressed: onForgetSaved,
              ),
              TextButton(
                onPressed: busy ? null : onResume,
                child: Text(s.rejoin,
                    style: TextStyle(color: AurumTheme.accentOf(context), fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
          const SizedBox(height: 14),
        ],

        // Start
        _Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.newRoom, style: TextStyle(color: tp, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              maxLength: 24,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              style: TextStyle(color: tp, fontSize: 16),
              decoration: _fieldDecoration(context, s.roomNameHint),
              onSubmitted: (_) => onStart(),
            ),
            const SizedBox(height: 12),
            _PrimaryButton(
              label: s.start,
              icon: Icons.play_arrow_rounded,
              onTap: onStart,
              busy: busy && last == _JamAction.start,
            ),
          ]),
        ),

        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: Divider(color: AurumTheme.dividerOf(context))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(s.or, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
          ),
          Expanded(child: Divider(color: AurumTheme.dividerOf(context))),
        ]),
        const SizedBox(height: 18),

        // Join
        _Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.joinWithCode, style: TextStyle(color: tp, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              maxLength: 20,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(color: tp, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2),
              decoration: _fieldDecoration(context, s.codeHint, prefix: JamService.codePrefix),
              onSubmitted: (_) => onJoin(),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: codeCtrl,
              builder: (_, v, __) => _PrimaryButton(
                label: s.join,
                icon: Icons.login_rounded,
                tonal: true,
                onTap: v.text.trim().isEmpty ? null : onJoin,
                busy: busy && last == _JamAction.join,
              ),
            ),
          ]),
        ),

        const SizedBox(height: 24),
        _SectionLabel(s.how.toUpperCase()),
        const SizedBox(height: 12),
        _Step(n: 1, text: s.how1),
        _Step(n: 2, text: s.how2),
        _Step(n: 3, text: s.how3),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final JamNotice notice;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;
  const _ErrorCard({required this.notice, required this.onRetry, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final offline = notice == JamNotice.connectionFailed;
    // "Room full" can't be fixed by retrying right away, so no retry there.
    final canRetry = notice != JamNotice.roomFull && notice != JamNotice.joinRejected;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: _kRed.withOpacity(0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kRed.withOpacity(0.35), width: 0.9),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(offline ? Icons.wifi_off_rounded : Icons.error_outline_rounded, color: _kRed, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.errorTitle, style: TextStyle(color: tp, fontSize: 14.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(s.notice(notice), style: TextStyle(color: ts, fontSize: 13, height: 1.35)),
            // Tiny diagnostic line (socket status / presence) so a screenshot
            // tells us exactly why a Jam didn't connect.
            if (JamService.instance.debugInfo.isNotEmpty &&
                (notice == JamNotice.roomNotFound || notice == JamNotice.connectionFailed))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(JamService.instance.debugInfo,
                    style: TextStyle(color: ts.withOpacity(0.6), fontSize: 10.5, height: 1.3)),
              ),
            if (canRetry) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () {
                  AurumHaptics.light();
                  onRetry();
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(s.retry, style: const TextStyle(color: _kRed, fontSize: 13.5, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ]),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close_rounded, color: ts, size: 18),
          onPressed: onDismiss,
        ),
      ]),
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
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: accent.withOpacity(0.16), shape: BoxShape.circle),
          child: Text('$n', style: TextStyle(color: accent, fontSize: 12.5, fontWeight: FontWeight.w800)),
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
  const _PreviewView({super.key, required this.onJoin, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);
    final room = jam.previewRoomName.isEmpty ? s.title : jam.previewRoomName;
    final hostName = jam.previewHostName;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: accent.withOpacity(0.16), borderRadius: BorderRadius.circular(20)),
            child: Text(
              s.preview.toUpperCase(),
              style: TextStyle(color: accent, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Center(child: _Avatar(url: jam.previewHostAvatar, name: hostName, size: 104, ring: accent)),
        const SizedBox(height: 18),
        Text(
          room,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: tp, fontSize: 27, fontWeight: FontWeight.w800, height: 1.15),
        ),
        if (hostName.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${s.hostedBy} $hostName', textAlign: TextAlign.center, style: TextStyle(color: ts, fontSize: 14.5)),
        ],
        const SizedBox(height: 24),
        _Card(
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: accent.withOpacity(0.16), borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.music_note_rounded, color: accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  s.nowPlaying.toUpperCase(),
                  style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1),
                ),
                const SizedBox(height: 3),
                Text(
                  jam.previewSong.isEmpty ? s.nothingYet : jam.previewSong,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tp, fontSize: 15, fontWeight: FontWeight.w700, height: 1.25),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Center(child: _AvatarStack(avatars: jam.previewAvatars, count: jam.previewCount)),
        const SizedBox(height: 26),
        _PrimaryButton(label: s.join, icon: Icons.login_rounded, onTap: onJoin),
        const SizedBox(height: 6),
        TextButton(
          onPressed: onCancel,
          child: Text(s.cancel, style: TextStyle(color: ts, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

/// Overlapping avatars + "2/4 in the room".
class _AvatarStack extends StatelessWidget {
  final List<String?> avatars;
  final int count;
  const _AvatarStack({required this.avatars, required this.count});

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final bg = AurumTheme.bgOf(context);
    const size = 34.0;
    const overlap = 24.0;
    final shown = avatars.length > JamService.maxMembers ? JamService.maxMembers : avatars.length;

    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (shown > 0)
        SizedBox(
          width: overlap * (shown - 1) + size,
          height: size,
          child: Stack(children: [
            for (var i = 0; i < shown; i++)
              Positioned(
                left: overlap * i,
                child: Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: bg, width: 2)),
                  child: _Avatar(url: avatars[i], name: '', size: size - 4),
                ),
              ),
          ]),
        ),
      if (shown > 0) const SizedBox(width: 12),
      Text('$count/${JamService.maxMembers} ${s.inRoom}', style: TextStyle(color: ts, fontSize: 13.5, fontWeight: FontWeight.w600)),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 3) Live room
// ─────────────────────────────────────────────────────────────────────────
class _RoomView extends StatelessWidget {
  final VoidCallback onLeave;
  const _RoomView({super.key, required this.onLeave});

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final accent = AurumTheme.accentOf(context);
    final reconnecting = jam.notice == JamNotice.reconnecting;
    final chipColor = (jam.myStatus == 'ok' && !reconnecting) ? _kGreen : _kAmber;
    final banner = jam.notice == JamNotice.waitingForFriend || reconnecting;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        // Title + live status chip
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Text(
              jam.roomName.isEmpty ? s.title : jam.roomName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tp, fontSize: 27, fontWeight: FontWeight.w800, height: 1.15),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: chipColor.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: chipColor, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(reconnecting ? s.reconnectingChip : s.status(jam.myStatus), style: TextStyle(color: chipColor, fontSize: 11.5, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),

        AnimatedSize(
          duration: AurumMotion.durationOrZero(AurumMotion.medium1),
          curve: AurumMotion.standard,
          alignment: Alignment.topCenter,
          child: !banner
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(color: accent.withOpacity(0.14), borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
                      const SizedBox(width: 12),
                      Expanded(child: Text(s.notice(jam.notice), style: TextStyle(color: tp, fontSize: 13.5))),
                    ]),
                  ),
                ),
        ),

        if (jam.isHost && jam.pendingRequests.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _RequestsCard(),
        ],
        if (jam.isHost && jam.suggestions.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SuggestionsCard(),
        ],

        const SizedBox(height: 20),
        _SectionLabel(s.nowPlaying.toUpperCase()),
        const SizedBox(height: 10),
        const _NowPlayingCard(),
        const SizedBox(height: 8),
        Text(
          jam.isHost ? s.hostHint : s.guestHint,
          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12.5, height: 1.35),
        ),

        const SizedBox(height: 22),
        const _InviteCard(),

        const SizedBox(height: 24),
        _SectionLabel('${s.people.toUpperCase()}  \u2022  ${jam.members.length}/${JamService.maxMembers}'),
        const SizedBox(height: 10),
        _MemberGrid(members: jam.members, myId: jam.myId),

        if (jam.collabTracks.isNotEmpty) ...[
          const SizedBox(height: 22),
          const _CollabCard(),
        ],

        const SizedBox(height: 22),
        _NudgeCard(),

        const SizedBox(height: 16),
        Center(
          child: TextButton.icon(
            onPressed: onLeave,
            icon: const Icon(Icons.logout_rounded, size: 18, color: _kRed),
            label: Text(s.leave, style: const TextStyle(color: _kRed, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard();

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final accent = AurumTheme.accentOf(context);
    final muted = AurumTheme.textMutedOf(context);

    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.codeLabel, style: TextStyle(color: muted, fontSize: 11, letterSpacing: 1.3, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            jam.fullCode,
            style: TextStyle(color: accent, fontSize: 27, fontWeight: FontWeight.w800, letterSpacing: 2),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: _PrimaryButton(
              label: s.copy,
              icon: Icons.copy_rounded,
              tonal: true,
              height: 48,
              onTap: () {
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
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _PrimaryButton(
              label: s.share,
              icon: Icons.ios_share_rounded,
              height: 48,
              onTap: () => _shareJam(context),
            ),
          ),
        ]),
      ]),
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
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;

    final placeholder = Container(
      color: accent.withOpacity(0.16),
      child: Icon(Icons.music_note_rounded, color: accent, size: 28),
    );

    return _Card(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 68,
            height: 68,
            child: (song == null || song.artworkUrl.isEmpty)
                ? placeholder
                : CachedNetworkImage(
                    imageUrl: song.artworkUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 136,
                    placeholder: (_, __) => Container(color: accent.withOpacity(0.12)),
                    errorWidget: (_, __, ___) => placeholder,
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              song?.title ?? s.nothingYet,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tp, fontSize: 16, fontWeight: FontWeight.w800, height: 1.2),
            ),
            if ((song?.artist ?? '').isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                song!.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: ts, fontSize: 13.5),
              ),
            ],
          ]),
        ),
        if (jam.isHost && song != null) ...[
          const SizedBox(width: 10),
          AurumPressable(
            onTap: () => playing ? jam.hostPause() : jam.hostResume(),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: onAccent,
                size: 30,
                semanticLabel: playing ? s.pauseAll : s.playAll,
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

// Video-call style member tiles, two per row. Big round DP with a status
// ring (green = in sync, amber = syncing). While the room has free slots,
// one "Invite a friend" tile sits at the end — tap to share.
class _MemberGrid extends StatelessWidget {
  final List<JamMember> members;
  final String? myId;
  const _MemberGrid({required this.members, required this.myId});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 10.0;
      final w = (c.maxWidth - gap) / 2;
      final hasFreeSlot = members.length < JamService.maxMembers;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final m in members)
            SizedBox(
              key: ValueKey(m.id),
              width: w,
              child: _PopIn(child: _MemberTile(m: m, isMe: m.id == myId)),
            ),
          if (hasFreeSlot) SizedBox(width: w, child: const _InviteSlot()),
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
    final ok = m.status == 'ok' && m.connected;
    final ring = ok ? _kGreen : _kAmber;
    final canManage = JamService.instance.isHost && !isMe;

    final tile = Container(
      height: 182,
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Avatar(url: m.avatar, name: m.name, size: 88, ring: ring),
          const SizedBox(height: 10),
          Text(
            isMe ? '${m.name} (${s.you})' : m.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: tp, fontSize: 14.5, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          if (m.isHost)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: accent.withOpacity(0.18), borderRadius: BorderRadius.circular(9)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.star_rounded, color: accent, size: 12),
                const SizedBox(width: 3),
                Text(s.host, style: TextStyle(color: accent, fontSize: 10.5, fontWeight: FontWeight.w800)),
              ]),
            )
          else
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: ring, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(m.connected ? s.status(m.status) : s.disconnectedTag, style: TextStyle(color: ts, fontSize: 12)),
            ]),
        ],
      ),
    );
    if (!canManage) return tile;
    return AurumPressable(
      onTap: () => _showMemberMenu(context, m),
      child: Stack(children: [
        tile,
        Positioned(
          top: 10,
          right: 12,
          child: Icon(Icons.more_horiz_rounded, color: ts, size: 20),
        ),
      ]),
    );
  }
}

/// Host: tap a member → hand over the Jam, remove, or remove & block.
void _showMemberMenu(BuildContext context, JamMember m) {
  final s = _S.of(context);
  final jam = JamService.instance;
  AurumHaptics.light();
  showAurumModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) {
      final tp = AurumTheme.textPrimaryOf(sheetCtx);
      final ts = AurumTheme.textSecondaryOf(sheetCtx);
      Widget row(IconData icon, String label, Color color, VoidCallback onTap) => AurumPressable(
            onTap: () {
              Navigator.pop(sheetCtx);
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 14),
                Text(label, style: TextStyle(color: color, fontSize: 15.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          );
      return SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          decoration: BoxDecoration(color: AurumTheme.bgCardOf(sheetCtx), borderRadius: BorderRadius.circular(24)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: ts.withOpacity(0.35), borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                _Avatar(url: m.avatar, name: m.name, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tp, fontSize: 17, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
            row(Icons.star_rounded, s.makeHost, tp, () => jam.transferHost(m.id)),
            row(Icons.person_remove_rounded, s.removeMember, _kRed, () => jam.kickUser(m.id)),
            row(Icons.block_rounded, s.blockMember, _kRed, () => jam.blockUser(m.name)),
          ]),
        ),
      );
    },
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Host cards: join requests + song suggestions
// ─────────────────────────────────────────────────────────────────────────
class _RequestsCard extends StatelessWidget {
  const _RequestsCard();

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final accent = AurumTheme.accentOf(context);
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionLabel(s.requestsTitle.toUpperCase()),
        const SizedBox(height: 12),
        for (final r in jam.pendingRequests)
          Padding(
            key: ValueKey(r.userId),
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              _Avatar(url: r.avatar, name: r.username, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.wantsToJoin(r.username),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tp, fontSize: 14.5, fontWeight: FontWeight.w700, height: 1.25)),
              ),
              IconButton(
                tooltip: s.reject,
                icon: const Icon(Icons.close_rounded, color: _kRed),
                onPressed: () {
                  AurumHaptics.light();
                  jam.rejectJoin(r.userId);
                },
              ),
              AurumPressable(
                onTap: () {
                  AurumHaptics.medium();
                  jam.approveJoin(r.userId);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(14)),
                  child: Text(s.approve, style: TextStyle(color: onAccent, fontWeight: FontWeight.w800, fontSize: 13.5)),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _SuggestionsCard extends StatelessWidget {
  const _SuggestionsCard();

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionLabel(s.suggestionsTitle.toUpperCase()),
        const SizedBox(height: 12),
        for (final g in jam.suggestions)
          Padding(
            key: ValueKey(g.id),
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: g.song.artworkUrl.isEmpty
                      ? Container(color: accent.withOpacity(0.16), child: Icon(Icons.music_note_rounded, color: accent))
                      : CachedNetworkImage(
                          imageUrl: g.song.artworkUrl,
                          fit: BoxFit.cover,
                          memCacheWidth: 92,
                          errorWidget: (_, __, ___) => Container(color: accent.withOpacity(0.16)),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tp, fontSize: 14.5, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text('${g.song.artist} \u2022 ${s.suggestedBy(g.fromUsername)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: ts, fontSize: 12)),
                ]),
              ),
              IconButton(
                tooltip: s.skip,
                icon: const Icon(Icons.close_rounded, color: _kRed),
                onPressed: () {
                  AurumHaptics.light();
                  jam.rejectSuggestion(g.id);
                },
              ),
              AurumPressable(
                onTap: () {
                  AurumHaptics.medium();
                  jam.approveSuggestion(g.id);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(14)),
                  child: Text(s.playNext, style: TextStyle(color: onAccent, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Jam playlist — every song played in this Jam, save it to the library
// ─────────────────────────────────────────────────────────────────────────
class _CollabCard extends StatelessWidget {
  const _CollabCard();

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final tracks = jam.collabTracks;
    const maxShown = 4;
    final shown = tracks.length > maxShown ? tracks.sublist(tracks.length - maxShown) : tracks;
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _SectionLabel('${s.collabTitle.toUpperCase()}  \u2022  ${tracks.length}')),
        ]),
        const SizedBox(height: 4),
        Text(s.collabHint, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12, height: 1.3)),
        const SizedBox(height: 10),
        for (final t in shown)
          Padding(
            key: ValueKey(t.id),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(Icons.music_note_rounded, size: 16, color: ts),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${t.title} \u2022 ${t.artist}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tp, fontSize: 13.5)),
              ),
            ]),
          ),
        if (tracks.length > maxShown)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Text(s.moreN(tracks.length - maxShown), style: TextStyle(color: ts, fontSize: 12.5)),
          ),
        const SizedBox(height: 10),
        _PrimaryButton(
          label: s.savePlaylist,
          icon: Icons.playlist_add_rounded,
          tonal: true,
          height: 46,
          onTap: () async {
            AurumHaptics.medium();
            final n = await jam.saveCollabAsPlaylist(context.read<PlaylistProvider>());
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(
                content: Text(s.savedN(n)),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
              ));
          },
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Waiting for the host to let us in
// ─────────────────────────────────────────────────────────────────────────
class _RequestingView extends StatefulWidget {
  final VoidCallback onCancel;
  const _RequestingView({super.key, required this.onCancel});

  @override
  State<_RequestingView> createState() => _RequestingViewState();
}

class _RequestingViewState extends State<_RequestingView> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    if (AurumMotion.enabled) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final jam = JamService.instance;
    final accent = AurumTheme.accentOf(context);
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, child) {
              final t = Curves.easeInOut.transform(_pulse.value);
              return Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withOpacity(0.05 + 0.12 * (1 - t)),
                ),
                child: child,
              );
            },
            child: _Avatar(url: jam.previewHostAvatar, name: jam.previewHostName, size: 96, ring: accent),
          ),
          const SizedBox(height: 22),
          Text(s.requesting, style: TextStyle(color: tp, fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(s.requestingBody,
              textAlign: TextAlign.center, style: TextStyle(color: ts, fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 18),
          TextButton(
            onPressed: widget.onCancel,
            child: Text(s.cancel, style: TextStyle(color: ts, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

class _InviteSlot extends StatelessWidget {
  const _InviteSlot();

  @override
  Widget build(BuildContext context) {
    final s = _S.of(context);
    final accent = AurumTheme.accentOf(context);
    return AurumPressable(
      onTap: () => _shareJam(context),
      child: Container(
        height: 182,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: accent.withOpacity(0.35), width: 1.2),
          color: accent.withOpacity(0.05),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: accent.withOpacity(0.16), shape: BoxShape.circle),
            child: Icon(Icons.person_add_alt_1_rounded, color: accent, size: 26),
          ),
          const SizedBox(height: 12),
          Text(
            s.inviteFriend,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(color: accent, fontSize: 13.5, fontWeight: FontWeight.w800),
          ),
        ]),
      ),
    );
  }
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

    // Collapsed by default — it's an advanced control, so it stays out of
    // the way until someone with Bluetooth earbuds needs it.
    return _Card(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Material(
          type: MaterialType.transparency,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          iconColor: ts,
          collapsedIconColor: ts,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Row(children: [
            Icon(Icons.tune_rounded, color: accent, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(s.fineTune, style: TextStyle(color: tp, fontSize: 15, fontWeight: FontWeight.w800))),
            Text(
              '${v >= 0 ? '+' : ''}${v.round()} ms',
              style: TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ]),
          children: [
            Text(s.fineTuneHint, style: TextStyle(color: ts, fontSize: 12.5, height: 1.3)),
            if (!jam.isHost && jam.driftMs != 0) ...[
              const SizedBox(height: 8),
              Text(
                jam.driftMs.abs() <= 35 ? s.liveSynced : s.liveOff(jam.driftMs),
                style: TextStyle(
                  color: jam.driftMs.abs() <= 35 ? _kGreen : _kAmber,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
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
                onChanged: (x) {
                  if (x.round() != v.round()) AurumHaptics.selection();
                  setState(() => _drag = x);
                },
                onChangeEnd: (x) {
                  jam.setNudge(x.round());
                  setState(() => _drag = null);
                },
              ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}
