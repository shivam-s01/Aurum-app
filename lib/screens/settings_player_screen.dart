import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../services/native_engine_bridge.dart';
import '../services/audio_prefs.dart';
import '../providers/recently_played_provider.dart';
import '../providers/premium_provider.dart';
import '../widgets/premium_gate.dart';
import '../widgets/aurum_pressable.dart';
import '../l10n/generated/app_localizations.dart';

// =============================================================================
// Sleep Timer Service — singleton so it survives screen navigation
// =============================================================================
class SleepTimerService {
  SleepTimerService._();
  static final SleepTimerService instance = SleepTimerService._();

  Timer? _timer;
  DateTime? _endsAt;
  bool _finishSong = false;
  NativeAudioEngine? _engine;

  // Listeners so UI can rebuild when timer ticks/ends
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() { for (final cb in _listeners) cb(); }

  bool get isActive => _timer != null && _timer!.isActive;
  Duration get remaining => isActive ? _endsAt!.difference(DateTime.now()) : Duration.zero;

  void start({
    required int minutes,
    required bool finishSong,
    required NativeAudioEngine? engine,
  }) {
    cancel();
    _finishSong = finishSong;
    _engine = engine;
    _endsAt = DateTime.now().add(Duration(minutes: minutes));
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _notify();
      if (DateTime.now().isAfter(_endsAt!)) {
        _onExpire();
      }
    });
    _notify();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    _notify();
  }

  void _onExpire() {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    if (_finishSong) {
      // Let current song finish, then pause at next song start
      _engine?.sleepAfterCurrentSong();
    } else {
      _engine?.pause();
    }
    _notify();
  }
}

// =============================================================================
// SettingsPlayerScreen
// =============================================================================
class SettingsPlayerScreen extends StatefulWidget {
  final NativeAudioEngine? audioEngine;
  const SettingsPlayerScreen({super.key, this.audioEngine});
  @override
  State<SettingsPlayerScreen> createState() => _SettingsPlayerScreenState();
}

class _SettingsPlayerScreenState extends State<SettingsPlayerScreen> {
  String _streamQuality = 'Auto';
  bool _dataSaver = false;
  bool _gapless = true;
  double _playbackSpeed = 1.0;
  bool _keepQueue = true;
  bool _stopOnSwipe = false;
  bool _pauseOnCall = true;
  bool _duckOnNotifications = false;
  bool _shakeToSkip = false;
  bool _swipeToChange = true;
  double _historyDuration = 50;

  // New settings
  double _crossfadeDuration = 0.0;   // seconds 0–12
  bool _volumeNormalization = false;
  bool _bassBoost = false;
  bool _premiumSound = false;
  PremiumSoundCapabilities? _premiumSoundCaps;

  // Sleep timer UI state
  bool _sleepTimerFinishSong = false;

  // FIX (toggle flash — see settings_appearance_screen.dart for the full
  // root-cause writeup): every field above defaults to a hardcoded value
  // before _load()'s async SharedPreferences read resolves, so the first
  // build() paints those hardcoded defaults for a frame, then snaps to the
  // real saved value once _load() completes. Gate the real UI behind a
  // brief loader until the real values are ready, so it only paints once.
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPremiumSoundCaps();
    SleepTimerService.instance.addListener(_onTimerTick);
  }

  Future<void> _loadPremiumSoundCaps() async {
    final caps = await widget.audioEngine?.getPremiumSoundCapabilities();
    if (mounted && caps != null) setState(() => _premiumSoundCaps = caps);
  }

  @override
  void dispose() {
    SleepTimerService.instance.removeListener(_onTimerTick);
    super.dispose();
  }

  void _onTimerTick() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final savedQuality = p.getString('stream_quality') ?? 'Auto';
    setState(() {
      // Defensive: if this was saved as 'High' before the payment gate
      // existed (or the account's premium lapsed), don't show a locked
      // option as the selected one — this matches what
      // AudioPrefs.qualityOrder() actually does at runtime regardless.
      _streamQuality       = (savedQuality == 'High' && !AudioPrefs.isPremium)
          ? 'Auto'
          : savedQuality;
      _dataSaver           = p.getBool('data_saver') ?? false;
      _gapless             = p.getBool('gapless') ?? true;
      _playbackSpeed       = p.getDouble('playback_speed') ?? 1.0;
      _keepQueue           = p.getBool('keep_queue') ?? true;
      _stopOnSwipe         = p.getBool('stop_on_swipe') ?? false;
      _pauseOnCall         = p.getBool('pause_on_call') ?? true;
      _duckOnNotifications = p.getBool('duck_on_notifications') ?? false;
      _shakeToSkip         = p.getBool('shake_to_skip') ?? false;
      _swipeToChange       = p.getBool('swipe_to_change') ?? true;
      _historyDuration     = (p.getInt('history_duration') ?? 50).toDouble();
      _crossfadeDuration   = p.getDouble('crossfade_duration') ?? 0.0;
      _volumeNormalization = p.getBool('volume_normalization') ?? false;
      _bassBoost           = p.getBool('bass_boost') ?? false;
      _premiumSound        = p.getBool('premium_sound') ?? false;
      _sleepTimerFinishSong = p.getBool('sleep_timer_finish_song') ?? false;
      _loaded = true;
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool)   await p.setBool(key, value);
    if (value is double) await p.setDouble(key, value);
    if (value is int)    await p.setInt(key, value);
    if (value is String) await p.setString(key, value);
  }

  // ── Stream Quality ──────────────────────────────────────────────────────
  //
  // Dedicated tile (not a generic dropdown) so "High Bitrate (320kbps)" can
  // be a clearly-locked, individually-tappable row — a plain
  // DropdownButton can't intercept a single item's tap to show a paywall
  // before committing the value. Tapping the locked row always opens
  // PremiumGate (payment only — this is the one feature in the app that
  // still requires Aurum Plus, not just a Google account) and never
  // silently selects it. The enforcement itself already lived in
  // AudioPrefs.qualityOrder() (free accounts capped at 160kbps); this tile
  // just makes that boundary visible and intentional in the UI instead of
  // free users picking "High" and silently getting capped audio.
  // Internal values MUST stay these exact English strings — they're persisted
  // to SharedPreferences and matched literally by AudioPrefs.qualityOrder()
  // and the native Kotlin side. Only the on-screen label is localized.
  static const _qualityKeys = ['Auto', 'Low', 'Medium', 'High'];
  List<(String key, String label, String subtitle, bool locked)> _qualityOptions(AppLocalizations l10n) => [
    ('Auto',   l10n.spQualityAuto,   l10n.spQualityAutoDesc,   false),
    ('Low',    l10n.spQualityLow,    l10n.spQualityLowDesc,    false),
    ('Medium', l10n.spQualityMedium, l10n.spQualityMediumDesc, false),
    ('High',   l10n.spQualityHigh,   l10n.spQualityHighDesc,   true), // locked = premium-only
  ];

  Widget _streamQualityTile(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isPremium = context.watch<PremiumProvider>().isPremium;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                    color: AurumTheme.gold.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.high_quality_rounded, color: AurumTheme.gold, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.spStreamQuality,
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    Text(l10n.spStreamQualitySubtitle,
                        style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          ..._qualityOptions(l10n).map((opt) {
            final (key, label, subtitle, locked) = opt;
            final isLocked = locked && !isPremium;
            final selected = _streamQuality == key;
            return AurumPressable(
              scaleAmount: 0.985,
              haptic: false,
              onTap: () {
                if (isLocked) {
                  HapticFeedback.mediumImpact();
                  // Strictly payment-gated — no requiresLoginOnly here.
                  // This is the one feature in the app a Google account
                  // alone does not unlock.
                  PremiumGate.show(
                    context,
                    feature: l10n.spPremiumHighBitrateFeature,
                    description: l10n.spPremiumHighBitrateDesc,
                  );
                  return;
                }
                HapticFeedback.selectionClick();
                setState(() => _streamQuality = key);
                _save('stream_quality', key);
                AudioPrefs.setStreamQuality(key);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? AurumTheme.gold.withOpacity(0.08)
                      : Colors.transparent,
                ),
                child: Row(children: [
                  Icon(
                    selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: selected ? AurumTheme.gold : AurumTheme.textMutedOf(context),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(label,
                              style: TextStyle(
                                color: isLocked
                                    ? AurumTheme.textMutedOf(context)
                                    : AurumTheme.textPrimaryOf(context),
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              )),
                          if (isLocked) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                gradient: AurumTheme.goldGradient,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.lock_rounded, color: Colors.black, size: 9),
                                const SizedBox(width: 2),
                                Text(l10n.spPlusBadge,
                                    style: const TextStyle(
                                        color: Colors.black,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.2)),
                              ]),
                            ),
                          ],
                        ]),
                        Text(subtitle,
                            style: TextStyle(
                              color: AurumTheme.textMutedOf(context).withOpacity(isLocked ? 0.7 : 1),
                              fontSize: 11.5,
                            )),
                      ],
                    ),
                  ),
                ]),
              ),
            );
          }),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  // Pushes current Bass Boost / Volume Normalization / EQ band settings to
  // the native AurumAudioEffects. Replaces the old
  // `audioHandler?.customAction('reloadSettings')` call — the Kotlin side
  // has no equivalent "reload from SharedPreferences" hook of its own, so
  // Dart reads prefs itself and sends the resolved values explicitly.
  Future<void> _notifyEngine() async {
    final p = await SharedPreferences.getInstance();
    final bandGains = List.generate(10, (i) => p.getDouble('eq_band_$i') ?? 0.0);
    await widget.audioEngine?.applyAudioEffects(
      bassBoost: _bassBoost,
      volumeNormalization: _volumeNormalization,
      bandGainsDb: bandGains,
    );
  }

  Widget _premiumSoundTile(BuildContext context, AppLocalizations l10n) {
    final value = _premiumSound;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        gradient: value
            ? LinearGradient(
                colors: [
                  AurumTheme.gold.withOpacity(0.16),
                  AurumTheme.gold.withOpacity(0.04),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: value ? null : AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value ? AurumTheme.gold.withOpacity(0.5) : AurumTheme.dividerOf(context),
          width: value ? 1 : 0.5,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            gradient: AurumTheme.goldGradient,
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.auto_awesome_rounded, color: Colors.black, size: 19),
        ),
        title: Text(l10n.spPremiumSound,
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 15, fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.spPremiumSoundSubtitle,
                  style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12, height: 1.3)),
              if (value && _premiumSoundCaps != null && !_premiumSoundCaps!.fullySupported)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10n.spPremiumSoundPartialSupport,
                    style: TextStyle(color: AurumTheme.gold.withOpacity(0.85), fontSize: 11, height: 1.3),
                  ),
                ),
            ],
          ),
        ),
        trailing: Switch(
          value: value,
          activeColor: AurumTheme.gold,
          onChanged: (v) async {
            setState(() => _premiumSound = v);
            await _save('premium_sound', v);
            await widget.audioEngine?.applyPremiumSound(v);
            if (v) await _loadPremiumSoundCaps();
          },
        ),
      ),
    );
  }

  // ── Sleep Timer Sheet ──────────────────────────────────────────────────────
  void _showSleepTimerSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SleepTimerSheet(
        engine: widget.audioEngine,
        finishSong: _sleepTimerFinishSong,
        onFinishSongChanged: (v) {
          setState(() => _sleepTimerFinishSong = v);
          _save('sleep_timer_finish_song', v);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final timer = SleepTimerService.instance;

    if (!_loaded) {
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        appBar: _appBar(context, l10n.settingsPlayerAudio),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, l10n.settingsPlayerAudio),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [

          // ── PLAYBACK ──────────────────────────────────────────────────────
          _sectionLabel(l10n.spPlayback),
          _streamQualityTile(context),
          _switchTile(context,
              icon: Icons.data_saver_on_rounded,
              title: l10n.spDataSaver,
              subtitle: l10n.spDataSaverSubtitle,
              value: _dataSaver,
              onChanged: (v) {
                setState(() => _dataSaver = v);
                _save('data_saver', v);
                AudioPrefs.setDataSaver(v);
              }),
          _switchTile(context,
              icon: Icons.remove_done_rounded,
              title: l10n.spGaplessPlayback,
              subtitle: l10n.spGaplessPlaybackSubtitle,
              value: _gapless,
              onChanged: (v) {
                setState(() => _gapless = v);
                _save('gapless', v);
                AudioPrefs.gapless = v;
              }),

          // Playback Speed
          _buildSpeedSlider(context),

          // Crossfade
          _buildCrossfadeSlider(context),

          // Premium Sound — flagship toggle: Virtualizer + native BassBoost
          // + extra loudness + presence/clarity EQ curve, composed on top
          // of whatever Bass Boost/Volume Normalization/manual EQ the user
          // already has set. Styled distinctly (gold gradient) since this
          // is the headline audio-quality feature.
          _premiumSoundTile(context, l10n),

          // Volume Normalization
          _switchTile(context,
              icon: Icons.equalizer_rounded,
              title: l10n.spVolumeNormalization,
              subtitle: l10n.spVolumeNormalizationSubtitle,
              value: _volumeNormalization,
              onChanged: (v) async {
                setState(() => _volumeNormalization = v);
                await _save('volume_normalization', v);
                await _notifyEngine();
              }),

          // Bass Boost
          _switchTile(context,
              icon: Icons.surround_sound_rounded,
              title: l10n.spBassBoost,
              subtitle: l10n.spBassBoostSubtitle,
              value: _bassBoost,
              onChanged: (v) async {
                setState(() => _bassBoost = v);
                await _save('bass_boost', v);
                await _notifyEngine();
              }),

          // ── SLEEP TIMER ───────────────────────────────────────────────────
          const SizedBox(height: 16),
          _sectionLabel(l10n.spSleepTimer),
          _buildSleepTimerTile(context, timer),

          // ── EQUALIZER ─────────────────────────────────────────────────────
          const SizedBox(height: 16),
          _sectionLabel(l10n.spEqualizer),
          _navTile(context,
              icon: Icons.graphic_eq_rounded,
              title: l10n.spEqualizerTitle,
              subtitle: l10n.spEqualizerSubtitle,
              onTap: () => Navigator.of(context)
                  .push(_slideRoute(EqualizerScreen(audioEngine: widget.audioEngine)))),

          // ── BEHAVIOR ──────────────────────────────────────────────────────
          const SizedBox(height: 16),
          _sectionLabel(l10n.spBehavior),
          _switchTile(context,
              icon: Icons.queue_music_rounded,
              title: l10n.spKeepQueue,
              subtitle: l10n.spKeepQueueSubtitle,
              value: _keepQueue,
              onChanged: (v) {
                setState(() => _keepQueue = v);
                _save('keep_queue', v);
              }),
          _switchTile(context,
              icon: Icons.clear_all_rounded,
              title: l10n.spStopOnSwipe,
              subtitle: l10n.spStopOnSwipeSubtitle,
              value: _stopOnSwipe,
              onChanged: (v) async {
                setState(() => _stopOnSwipe = v);
                await _save('stop_on_swipe', v);
                await AudioPrefs.setStopOnSwipe(v);
              }),
          _switchTile(context,
              icon: Icons.call_rounded,
              title: l10n.spPauseOnCall,
              subtitle: l10n.spPauseOnCallSubtitle,
              value: _pauseOnCall,
              onChanged: (v) {
                setState(() => _pauseOnCall = v);
                _save('pause_on_call', v);
                AudioPrefs.setPauseOnCall(v);
              }),
          _switchTile(context,
              icon: Icons.notifications_active_rounded,
              title: l10n.spDuckNotifications,
              subtitle: l10n.spDuckNotificationsSubtitle,
              value: _duckOnNotifications,
              onChanged: (v) {
                setState(() => _duckOnNotifications = v);
                _save('duck_on_notifications', v);
                AudioPrefs.setDuckOnNotifications(v);
              }),
          _switchTile(context,
              icon: Icons.vibration_rounded,
              title: l10n.spShakeToSkip,
              subtitle: l10n.spShakeToSkipSubtitle,
              value: _shakeToSkip,
              onChanged: (v) async {
                setState(() => _shakeToSkip = v);
                await _save('shake_to_skip', v);
                await AudioPrefs.setShakeToSkip(v);
              }),
          _switchTile(context,
              icon: Icons.swipe_rounded,
              title: l10n.spSwipeToChange,
              subtitle: l10n.spSwipeToChangeSubtitle,
              value: _swipeToChange,
              onChanged: (v) {
                setState(() => _swipeToChange = v);
                _save('swipe_to_change', v);
                AudioPrefs.setSwipeToChange(v);
              }),

          // History Duration
          _buildHistorySlider(context),
        ],
      ),
    );
  }

  // ── Speed Slider ─────────────────────────────────────────────────────────
  Widget _buildSpeedSlider(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.speed_rounded, color: AurumTheme.gold, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.spPlaybackSpeed,
                    style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
                Text(l10n.spPlaybackSpeedSubtitle,
                    style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _playbackSpeed == 1.0 ? l10n.spNormal : '${_playbackSpeed}×',
                  style: const TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Slider(
              value: _playbackSpeed,
              min: 0.25, max: 2.0, divisions: 7,
              onChanged: (v) => setState(() => _playbackSpeed = v),
              onChangeEnd: (v) async {
                await _save('playback_speed', v);
                await widget.audioEngine?.setSpeed(v);
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const ['0.25×','0.5×','0.75×','1×','1.25×','1.5×','1.75×','2×']
                  .map((l) => Text(l, style: TextStyle(color: AurumTheme.gold, fontSize: 9)))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Crossfade Slider ──────────────────────────────────────────────────────
  Widget _buildCrossfadeSlider(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.compare_arrows_rounded, color: AurumTheme.gold, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.spCrossfade,
                    style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
                Text(l10n.spCrossfadeSubtitle,
                    style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _crossfadeDuration == 0 ? l10n.spOff : '${_crossfadeDuration.toInt()}s',
                  style: const TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Slider(
              value: _crossfadeDuration,
              min: 0, max: 12, divisions: 12,
              onChanged: (v) => setState(() => _crossfadeDuration = v),
              onChangeEnd: (v) async {
                await _save('crossfade_duration', v);
                await widget.audioEngine?.setCrossfadeSeconds(v);
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const ['Off','1s','2s','3s','4s','5s','6s','7s','8s','9s','10s','11s','12s']
                  .map((l) => Text(l, style: TextStyle(color: AurumTheme.gold, fontSize: 9)))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Sleep Timer Tile ──────────────────────────────────────────────────────
  Widget _buildSleepTimerTile(BuildContext context, SleepTimerService timer) {
    final l10n = AppLocalizations.of(context)!;
    final isActive = timer.isActive;
    final remaining = timer.remaining;
    final mm = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive ? AurumTheme.gold.withOpacity(0.5) : AurumTheme.dividerOf(context),
          width: isActive ? 1 : 0.5,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: isActive ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.gold.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.bedtime_rounded, color: AurumTheme.gold, size: 18),
        ),
        title: Text(
          isActive ? l10n.spSleepTimerActive : l10n.spSleepTimerTitle,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 14, fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          isActive ? l10n.spSleepTimerStopsIn('$mm:$ss') : l10n.spSleepTimerSetSubtitle,
          style: TextStyle(
            color: isActive ? AurumTheme.gold : AurumTheme.textMutedOf(context),
            fontSize: 12,
          ),
        ),
        trailing: isActive
            ? GestureDetector(
                onTap: () => SleepTimerService.instance.cancel(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                  ),
                  child: Text(l10n.spCancel,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              )
            : Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context), size: 20),
        onTap: isActive ? null : () => _showSleepTimerSheet(context),
      ),
    );
  }

  // ── History Slider ────────────────────────────────────────────────────────
  Widget _buildHistorySlider(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(children: [
          Row(children: [
            Text(l10n.spHistoryDuration,
                style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
            const Spacer(),
            Text(l10n.spHistorySongsCount(10 + (_historyDuration / 100.0 * 190).round()),
                style: const TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
          Slider(
            value: _historyDuration,
            min: 10, max: 100, divisions: 9,
            onChanged: (v) {
              setState(() => _historyDuration = v);
              _save('history_duration', v.toInt());
              // Trim existing history to new limit immediately
              context.read<RecentlyPlayedProvider>()
                  .trimToLimit((10 + (v / 100.0 * 190).round()).clamp(10, 200));
            },
          ),
        ]),
      ),
    );
  }
}

// =============================================================================
// Sleep Timer Bottom Sheet
// =============================================================================
class SleepTimerSheet extends StatefulWidget {
  final NativeAudioEngine? engine;
  final bool finishSong;
  final ValueChanged<bool> onFinishSongChanged;

  const SleepTimerSheet({
    required this.engine,
    required this.finishSong,
    required this.onFinishSongChanged,
  });

  @override
  State<SleepTimerSheet> createState() => SleepTimerSheetState();
}

class SleepTimerSheetState extends State<SleepTimerSheet> {
  int _selectedMinutes = 30;
  late bool _finishSong;

  static const _presets = [5, 10, 15, 20, 30, 45, 60, 90];

  @override
  void initState() {
    super.initState();
    _finishSong = widget.finishSong;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AurumTheme.dividerOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(l10n.spSleepTimerSheetTitle,
              style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(l10n.spSleepTimerSheetSubtitle,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
          const SizedBox(height: 20),

          // Preset chips
          Wrap(
            spacing: 8, runSpacing: 8,
            children: _presets.map((min) {
              final sel = _selectedMinutes == min;
              return GestureDetector(
                onTap: () => setState(() => _selectedMinutes = min),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgOf(context),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: sel ? AurumTheme.gold.withOpacity(0.6) : AurumTheme.dividerOf(context),
                      width: sel ? 1 : 0.5,
                    ),
                  ),
                  child: Text(
                    min < 60 ? '${min}m' : '${min ~/ 60}h',
                    style: TextStyle(
                      color: sel ? AurumTheme.gold : AurumTheme.textSecondaryOf(context),
                      fontSize: 14, fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),

          // Finish song toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: AurumTheme.bgOf(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.spFinishCurrentSong,
                        style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
                    Text(l10n.spFinishCurrentSongSubtitle,
                        style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
                  ]),
                ),
                Switch(
                  value: _finishSong,
                  onChanged: (v) {
                    setState(() => _finishSong = v);
                    widget.onFinishSongChanged(v);
                  },
                  activeColor: AurumTheme.gold,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Start button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                SleepTimerService.instance.start(
                  minutes: _selectedMinutes,
                  finishSong: _finishSong,
                  engine: widget.engine,
                );
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AurumTheme.gold,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Text(
                l10n.spStartTimer(_selectedMinutes < 60 ? "${_selectedMinutes}m" : "${_selectedMinutes ~/ 60}h"),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (SleepTimerService.instance.isActive) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () {
                  SleepTimerService.instance.cancel();
                  Navigator.pop(context);
                },
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  l10n.spCancelActiveTimer,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Equalizer Screen
// =============================================================================
class EqualizerScreen extends StatefulWidget {
  final NativeAudioEngine? audioEngine;
  const EqualizerScreen({this.audioEngine});
  @override
  State<EqualizerScreen> createState() => EqualizerScreenState();
}

class EqualizerScreenState extends State<EqualizerScreen> {
  static const _bands = ['32Hz','64Hz','125Hz','250Hz','500Hz','1kHz','2kHz','4kHz','8kHz','16kHz'];
  static const _presets = {
    'Flat':       [0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
    'Rock':       [4.0,3.0,1.0,0.0,-1.0,-1.0,0.0,2.0,3.0,4.0],
    'Pop':        [-1.0,0.0,2.0,3.0,3.0,2.0,1.0,0.0,-1.0,-2.0],
    'Jazz':       [3.0,2.0,1.0,2.0,-1.0,-1.0,0.0,1.0,2.0,3.0],
    'Bass Boost': [6.0,5.0,4.0,2.0,0.0,0.0,0.0,0.0,0.0,0.0],
    'Vocal':      [-2.0,-1.0,0.0,2.0,4.0,4.0,3.0,2.0,1.0,0.0],
    'Electronic': [5.0,4.0,1.0,0.0,-2.0,1.0,0.0,2.0,4.0,5.0],
  };

  List<double> _values = List.filled(10, 0.0);
  String _selectedPreset = 'Flat';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _selectedPreset = p.getString('eq_preset') ?? 'Flat';
      _values = List.generate(10, (i) => p.getDouble('eq_band_$i') ?? 0.0);
    });
  }

  Future<void> _saveValues() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('eq_preset', _selectedPreset);
    for (int i = 0; i < 10; i++) {
      await p.setDouble('eq_band_$i', _values[i]);
    }
    // Bass Boost / Volume Normalization toggles live in
    // SettingsPlayerScreen's state, not here — read the persisted values
    // fresh so a custom EQ curve edit doesn't accidentally clobber them.
    final bassBoost = p.getBool('bass_boost') ?? false;
    final volNorm = p.getBool('volume_normalization') ?? false;
    await widget.audioEngine?.applyAudioEffects(
      bassBoost: bassBoost,
      volumeNormalization: volNorm,
      bandGainsDb: _values,
    );
  }

  void _applyPreset(String name) {
    setState(() {
      _selectedPreset = name;
      _values = List.from(_presets[name]!);
    });
    _saveValues();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, l10n.spEqualizerTitle, actions: [
        TextButton(
          onPressed: () => _applyPreset('Flat'),
          child: Text(l10n.spEqReset, style: const TextStyle(color: AurumTheme.gold, fontSize: 14)),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          _sectionLabel(l10n.spEqPresets),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: _presets.keys.map((preset) {
              final sel = _selectedPreset == preset;
              return GestureDetector(
                onTap: () => _applyPreset(preset),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgCardOf(context),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: sel ? AurumTheme.gold.withOpacity(0.6) : AurumTheme.dividerOf(context),
                      width: sel ? 1 : 0.5,
                    ),
                  ),
                  child: Text(preset,
                      style: TextStyle(
                        color: sel ? AurumTheme.gold : AurumTheme.textSecondaryOf(context),
                        fontSize: 13, fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      )),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
          _sectionLabel(l10n.spEq10Band),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: Column(
              children: List.generate(10, (i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                      width: 44,
                      child: Text(_bands[i],
                          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11),
                          textAlign: TextAlign.right)),
                  Expanded(
                    child: Slider(
                      value: _values[i],
                      min: -12, max: 12, divisions: 24,
                      onChanged: (v) => setState(() {
                        _values[i] = v;
                        _selectedPreset = 'Custom';
                      }),
                      onChangeEnd: (_) => _saveValues(),
                    ),
                  ),
                  SizedBox(
                      width: 38,
                      child: Text(
                        '${_values[i] >= 0 ? '+' : ''}${_values[i].toStringAsFixed(0)}dB',
                        style: TextStyle(
                          color: _values[i] == 0 ? AurumTheme.textMutedOf(context) : AurumTheme.gold,
                          fontSize: 10, fontWeight: FontWeight.w600,
                        ),
                      )),
                ]),
              )),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Shared Helpers
// =============================================================================
AppBar _appBar(BuildContext context, String title, {List<Widget>? actions}) =>
    AppBar(
      backgroundColor: AurumTheme.bgOf(context),
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new_rounded,
            color: AurumTheme.textPrimaryOf(context), size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(title,
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 18, fontWeight: FontWeight.w600)),
      actions: actions,
    );

Widget _sectionLabel(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(label,
          style: const TextStyle(
              color: AurumTheme.gold,
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
    );

Widget _switchTile(BuildContext context,
    {required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged}) =>
    Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: value ? AurumTheme.gold.withOpacity(0.12) : AurumTheme.bgOf(context),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon,
              color: value ? AurumTheme.gold : AurumTheme.textMutedOf(context),
              size: 18),
        ),
        title: Text(title,
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle,
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
        trailing: Switch(value: value, onChanged: onChanged, activeColor: AurumTheme.gold),
      ),
    );

Widget _dropdownTile(BuildContext context,
    {required IconData icon,
    required String title,
    required String subtitle,
    required String value,
    required List<String> options,
    required ValueChanged<String?> onChanged}) =>
    Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
              color: AurumTheme.gold.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: AurumTheme.gold, size: 18),
        ),
        title: Text(title,
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle,
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
        trailing: DropdownButton<String>(
          value: value,
          underline: const SizedBox(),
          dropdownColor: AurumTheme.bgCardOf(context),
          style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600),
          icon: Icon(Icons.keyboard_arrow_down_rounded, color: AurumTheme.gold, size: 18),
          items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
          onChanged: onChanged,
        ),
      ),
    );

Widget _navTile(BuildContext context,
    {required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap}) =>
    Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
              color: AurumTheme.gold.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: AurumTheme.gold, size: 18),
        ),
        title: Text(title,
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle,
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
        trailing: Icon(Icons.chevron_right_rounded,
            color: AurumTheme.textMutedOf(context), size: 20),
      ),
    );

PageRouteBuilder _slideRoute(Widget screen) => PageRouteBuilder(
      pageBuilder: (_, animation, __) => screen,
      transitionsBuilder: (_, animation, __, child) {
        final tween = Tween(begin: const Offset(1.0, 0.0), end: Offset.zero)
            .chain(CurveTween(curve: Curves.easeOutCubic));
        return SlideTransition(position: animation.drive(tween), child: child);
      },
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 250),
    );
