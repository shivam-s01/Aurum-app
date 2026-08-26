import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../services/native_engine_bridge.dart';
import '../services/audio_prefs.dart';
import '../providers/recently_played_provider.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/auto_sleep_guard_tile.dart';
import '../widgets/battery_saver_mode_tile.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';

// =============================================================================
// Sleep Timer Service — singleton so it survives screen navigation
// =============================================================================
class SleepTimerService {
  SleepTimerService._();
  static final SleepTimerService instance = SleepTimerService._();

  Timer? _timer;
  DateTime? _endsAt;
  bool _finishSong = false;
  bool _fadeOut = true;
  NativeAudioEngine? _engine;

  // Listeners so UI can rebuild when timer ticks/ends
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() { for (final cb in _listeners) cb(); }

  bool get isActive => _timer != null && _timer!.isActive;
  Duration get remaining => isActive ? _endsAt!.difference(DateTime.now()) : Duration.zero;

  /// Last fade-out preference used (defaults true) — lets any sheet that
  /// opens the timer show the same choice the user last made in Settings,
  /// without each call site needing its own SharedPreferences read.
  bool get lastFadeOutChoice => _fadeOut;

  void start({
    required int minutes,
    required bool finishSong,
    required NativeAudioEngine? engine,
    bool fadeOut = true,
  }) {
    cancel();
    _finishSong = finishSong;
    _fadeOut = fadeOut;
    _engine = engine;
    _endsAt = DateTime.now().add(Duration(minutes: minutes));
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _notify();
      if (DateTime.now().isAfter(_endsAt!)) {
        _onExpire();
      }
    });
    // Auto Sleep Guard (a separate, native battery feature) must stay
    // completely silent while this Sleep Timer is running — see
    // AutoSleepGuard.kt. Pushed here rather than polled from native side
    // so there's no cross-language polling in either direction.
    _engine?.autoSleepGuardSetSleepTimerActive(true);
    _notify();
  }

  void cancel() {
    final wasActive = isActive;
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    if (wasActive) {
      _engine?.autoSleepGuardSetSleepTimerActive(false);
    }
    _notify();
  }

  void _onExpire() {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    _engine?.autoSleepGuardSetSleepTimerActive(false);
    if (_finishSong) {
      // Let current song finish, then pause at next song start
      _engine?.sleepAfterCurrentSong();
    } else if (_fadeOut) {
      // Apple-style smooth wind-down instead of an abrupt cut.
      _engine?.sleepFadeOutAndPause(fadeMs: 8000);
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
  String _castIconVisibility = 'auto';
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
  bool _sleepTimerFadeOut = true;
  String _hapticIntensity = 'light';

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
    if (!mounted) return;
    setState(() {
      // 320kbps ('High') is fully free now — no defensive downgrade needed.
      _streamQuality       = savedQuality;
      _dataSaver           = p.getBool('data_saver') ?? false;
      _gapless             = p.getBool('gapless') ?? true;
      _castIconVisibility  = p.getString('cast_icon_visibility') ?? 'auto';
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
      _sleepTimerFadeOut = p.getBool('sleep_timer_fade_out') ?? true;
      _hapticIntensity = AurumHaptics.intensity;
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
  // 320kbps ('High') is fully free now — no sign-in, no payment required.
  // Every tier is directly selectable; nothing here is locked anymore.
  // Internal values MUST stay these exact English strings — they're persisted
  // to SharedPreferences and matched literally by AudioPrefs.qualityOrder()
  // and the native Kotlin side. Only the on-screen label is localized.
  static const _qualityKeys = ['Auto', 'Low', 'DataSaver', 'Medium', 'High'];
  List<(String key, String label, String subtitle, bool locked)> _qualityOptions(AppLocalizations l10n) => [
    ('Auto',   l10n.spQualityAuto,   l10n.spQualityAutoDesc,   false),
    ('Low',    l10n.spQualityLow,    l10n.spQualityLowDesc,    false),
    ('DataSaver', l10n.spQualityDataSaver, l10n.spQualityDataSaverDesc, false),
    ('Medium', l10n.spQualityMedium, l10n.spQualityMediumDesc, false),
    ('High',   l10n.spQualityHigh,   l10n.spQualityHighDesc,   false),
  ];

  Widget _streamQualityTile(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
            final (key, label, subtitle, _) = opt;
            final selected = _streamQuality == key;
            return AurumPressable(
              scaleAmount: 0.985,
              haptic: false,
              onTap: () {
                AurumHaptics.selection();
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
                        Text(label,
                            style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            )),
                        Text(subtitle,
                            style: TextStyle(
                              color: AurumTheme.textMutedOf(context),
                              fontSize: 11.5,
                            )),
                        // "Smart Saver" (DataSaver) is the one tier whose
                        // short label alone doesn't fully explain the
                        // behaviour — its whole point is that it silently
                        // adapts per song. Rather than always showing that
                        // longer explanation in the collapsed list (which
                        // would make the list feel cluttered/AI-written),
                        // it only reveals once the user has actually
                        // picked it — a quiet confirmation of what they
                        // just turned on, the way a considered, premium
                        // settings screen would do it.
                        if (key == 'DataSaver' && selected) ...[
                          const SizedBox(height: 3),
                          Text(l10n.spQualityDataSaverDescExpanded,
                              style: TextStyle(
                                color: AurumTheme.textMutedOf(context).withOpacity(0.85),
                                fontSize: 11,
                                height: 1.35,
                              )),
                        ],
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
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      isScrollControlled: true, // needed so the custom-duration keyboard doesn't cover the sheet
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SleepTimerSheet(
        engine: widget.audioEngine,
        finishSong: _sleepTimerFinishSong,
        fadeOut: _sleepTimerFadeOut,
        onFinishSongChanged: (v) {
          setState(() => _sleepTimerFinishSong = v);
          _save('sleep_timer_finish_song', v);
        },
        onFadeOutChanged: (v) {
          setState(() => _sleepTimerFadeOut = v);
          _save('sleep_timer_fade_out', v);
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
        // Was missing the BouncingScrollPhysics every other settings
        // screen uses — without it this list fell back to Android's
        // default ClampingScrollPhysics (hard-stops at the edges, no
        // overscroll give), which is what made this one screen feel
        // stuck/rigid compared to the rest of Settings.
        physics: const BouncingScrollPhysics(),
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

          // Auto Sleep Guard — placed right under Data Saver since both
          // are battery-related, but styled distinctly (its own gold-
          // accented card, not a plain switch tile) so it reads as a
          // standalone premium-feeling feature, not a minor toggle.
          const AutoSleepGuardTile(),

          // Battery Saver Mode — right below Auto Sleep Guard since both
          // are battery-focused features sharing the same premium card
          // treatment. Distinct from Auto Sleep Guard: this one never
          // touches playback, only visual effects (animations, blur,
          // breathing background), and reacts live to actual battery %
          // rather than inactivity time.
          const BatterySaverModeTile(),

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
          _dropdownTile(context,
              icon: Icons.cast_rounded,
              title: l10n.spShowCastIcon,
              subtitle: l10n.spShowCastIconSubtitle,
              value: _castIconVisibilityLabel(l10n, _castIconVisibility),
              options: [
                _castIconVisibilityLabel(l10n, 'auto'),
                _castIconVisibilityLabel(l10n, 'always'),
                _castIconVisibilityLabel(l10n, 'hidden'),
              ],
              onChanged: (label) {
                if (label == null) return;
                final key = _castIconVisibilityKeyFromLabel(l10n, label);
                AurumHaptics.selection();
                setState(() => _castIconVisibility = key);
                _save('cast_icon_visibility', key);
                AudioPrefs.setCastIconVisibility(key);
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
          _dropdownTile(context,
              icon: Icons.vibration_rounded,
              title: l10n.spHapticIntensity,
              subtitle: l10n.spHapticIntensitySubtitle,
              value: _hapticIntensityLabel(l10n, _hapticIntensity),
              options: [
                _hapticIntensityLabel(l10n, 'off'),
                _hapticIntensityLabel(l10n, 'light'),
                _hapticIntensityLabel(l10n, 'strong'),
              ],
              onChanged: (label) {
                if (label == null) return;
                final key = _hapticIntensityKeyFromLabel(l10n, label);
                setState(() => _hapticIntensity = key);
                AurumHaptics.setIntensity(key);
                // Immediate preview so picking "Strong" is felt right away
                // instead of the user having to leave Settings to notice
                // anything changed.
                AurumHaptics.medium();
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
  final bool fadeOut;
  final ValueChanged<bool> onFinishSongChanged;
  final ValueChanged<bool> onFadeOutChanged;

  const SleepTimerSheet({
    required this.engine,
    required this.finishSong,
    this.fadeOut = true,
    required this.onFinishSongChanged,
    required this.onFadeOutChanged,
  });

  @override
  State<SleepTimerSheet> createState() => SleepTimerSheetState();
}

class SleepTimerSheetState extends State<SleepTimerSheet> {
  int _selectedMinutes = 30;
  late bool _finishSong;
  late bool _fadeOut;

  // Custom-duration text field state
  bool _customMode = false;
  final TextEditingController _customController = TextEditingController();
  final FocusNode _customFocusNode = FocusNode();
  String? _customError;

  static const _presets = [5, 10, 15, 20, 30, 45, 60, 90];
  static const int _maxCustomMinutes = 600; // 10h — generous ceiling, guards against fat-finger overflow

  @override
  void initState() {
    super.initState();
    _finishSong = widget.finishSong;
    _fadeOut = widget.fadeOut;
  }

  @override
  void dispose() {
    _customController.dispose();
    _customFocusNode.dispose();
    super.dispose();
  }

  /// Formats a minute count the way a premium app would — no duplicate
  /// labels for different durations (the old `min ~/ 60` truncation made
  /// both 60 and 90 minutes display as "1h"). Shows minutes for anything
  /// under an hour, and "Xh" / "Xh Ym" above it.
  String _formatMinutes(int min) {
    if (min < 60) return '${min}m';
    final h = min ~/ 60;
    final m = min % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  void _enterCustomMode() {
    AurumHaptics.selection();
    setState(() {
      _customMode = true;
      _customError = null;
      _customController.text = _selectedMinutes.toString();
      _customController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _customController.text.length,
      );
    });
    // Open the keyboard right away — this is the whole point of custom mode.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _customFocusNode.requestFocus();
    });
  }

  void _confirmCustomMinutes() {
    final l10n = AppLocalizations.of(context)!;
    final raw = _customController.text.trim();
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      setState(() => _customError = l10n.spSleepTimerInvalidDuration);
      return;
    }
    if (parsed > _maxCustomMinutes) {
      setState(() => _customError =
          l10n.spSleepTimerMaxDuration(_maxCustomMinutes));
      return;
    }
    AurumHaptics.light();
    setState(() {
      _selectedMinutes = parsed;
      _customMode = false;
      _customError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isCustomPreset = !_presets.contains(_selectedMinutes);

    return Padding(
      // Lifts the whole sheet above the keyboard when the custom-duration
      // field is focused, instead of the keyboard just covering it.
      padding: EdgeInsets.fromLTRB(
        20, 20, 20, 36 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
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

            if (!_customMode) ...[
              // Preset chips + Custom chip
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  ..._presets.map((min) {
                    final sel = !isCustomPreset && _selectedMinutes == min;
                    return _DurationChip(
                      label: _formatMinutes(min),
                      selected: sel,
                      onTap: () {
                        AurumHaptics.selection();
                        setState(() => _selectedMinutes = min);
                      },
                    );
                  }),
                  // Custom chip — shows the current custom value once set,
                  // otherwise an edit-pencil affordance so it reads as
                  // "type your own" rather than a mystery button.
                  _DurationChip(
                    label: isCustomPreset
                        ? _formatMinutes(_selectedMinutes)
                        : l10n.spSleepTimerCustom,
                    selected: isCustomPreset,
                    icon: Icons.edit_rounded,
                    onTap: _enterCustomMode,
                  ),
                ],
              ),
            ] else ...[
              // Custom duration entry — keyboard-driven, Apple-Clock-style.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: AurumTheme.bgOf(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _customError != null
                        ? Colors.redAccent.withOpacity(0.6)
                        : AurumTheme.gold.withOpacity(0.4),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customController,
                        focusNode: _customFocusNode,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        maxLength: 3,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          counterText: '',
                          hintText: '30',
                          hintStyle: TextStyle(
                            color: AurumTheme.textMutedOf(context).withOpacity(0.4),
                          ),
                        ),
                        onChanged: (_) {
                          if (_customError != null) {
                            setState(() => _customError = null);
                          }
                        },
                        onSubmitted: (_) => _confirmCustomMinutes(),
                      ),
                    ),
                    Text(l10n.spSleepTimerMinutesUnit,
                        style: TextStyle(
                          color: AurumTheme.textMutedOf(context),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        )),
                  ],
                ),
              ),
              if (_customError != null) ...[
                const SizedBox(height: 6),
                Text(_customError!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        _customFocusNode.unfocus();
                        setState(() {
                          _customMode = false;
                          _customError = null;
                        });
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: AurumTheme.textMutedOf(context),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(l10n.commonCancel,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _confirmCustomMinutes,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AurumTheme.gold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: Text(l10n.spSleepTimerSetDuration,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),

            // Fade-out toggle
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
                      Text(l10n.spSleepTimerFadeOut,
                          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
                      Text(l10n.spSleepTimerFadeOutSubtitle,
                          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
                    ]),
                  ),
                  Switch(
                    value: _fadeOut,
                    onChanged: (v) {
                      AurumHaptics.selection();
                      setState(() => _fadeOut = v);
                      widget.onFadeOutChanged(v);
                    },
                    activeColor: AurumTheme.gold,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

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
                      AurumHaptics.selection();
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
                onPressed: _customMode
                    ? null // must confirm or cancel custom entry first
                    : () {
                        AurumHaptics.medium();
                        SleepTimerService.instance.start(
                          minutes: _selectedMinutes,
                          finishSong: _finishSong,
                          fadeOut: _fadeOut,
                          engine: widget.engine,
                        );
                        Navigator.pop(context);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AurumTheme.gold,
                  disabledBackgroundColor: AurumTheme.gold.withOpacity(0.3),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: Text(
                  l10n.spStartTimer(_formatMinutes(_selectedMinutes)),
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
                    AurumHaptics.medium();
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
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Duration selection chip — shared by presets and the "Custom" entry point
// ─────────────────────────────────────────────────────────────────────────────
class _DurationChip extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData? icon;
  final VoidCallback onTap;

  const _DurationChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AurumTheme.gold.withOpacity(0.6) : AurumTheme.dividerOf(context),
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13,
                  color: selected ? AurumTheme.gold : AurumTheme.textSecondaryOf(context)),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? AurumTheme.gold : AurumTheme.textSecondaryOf(context),
                fontSize: 14, fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Equalizer Screen — production redesign
//
// Scope note: this class was rebuilt visually/UX-wise only. All existing
// persistence keys ('eq_preset', 'eq_band_$i', 'bass_boost',
// 'volume_normalization'), the preset table, band frequencies, and the
// applyAudioEffects()/bandGainsDb pipeline are unchanged — see _load(),
// _saveValues(), and _applyPreset() below, which are the same logic as
// before with one additive extension (bassBoostPercent, see its own doc
// comment) layered on top, never replacing it.
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

  // Approximate center frequency of each band, used only to place points
  // on the response graph (log-spaced x-axis) — purely presentational,
  // does not feed back into the real DSP path in any way.
  static const _bandFreqsHz = [32,64,125,250,500,1000,2000,4000,8000,16000];

  // ── Isolated rebuild state ──────────────────────────────────────────────
  // Band values, the selected preset name, and the Bass Boost percentage
  // live in ValueNotifiers rather than plain setState fields. This is a
  // PERFORMANCE-ONLY change — same data, same persistence keys, same
  // applyAudioEffects() wiring below — but it means dragging a band
  // slider or a curve node only rebuilds the small ValueListenableBuilder
  // around that value (see build() below), instead of rebuilding the
  // entire Equalizer screen (preset card, bass boost card, all 10 other
  // sliders, the graph) on every drag frame. Matters for staying smooth
  // at 60fps on the low-end devices Aurum targets, especially since the
  // curve's CustomPaint and 10 sliders would otherwise all repaint on
  // every single pixel of a drag.
  final ValueNotifier<List<double>> _valuesNotifier =
      ValueNotifier<List<double>>(List.filled(10, 0.0));
  final ValueNotifier<String> _presetNotifier = ValueNotifier<String>('Flat');
  final ValueNotifier<double> _bassBoostNotifier = ValueNotifier<double>(0.0);

  bool _loaded = false;

  List<double> get _values => _valuesNotifier.value;
  String get _selectedPreset => _presetNotifier.value;
  double get _bassBoostPercent => _bassBoostNotifier.value;

  // Max additive dB this slider can contribute at 100%, split across the
  // two lowest bands (sub-bass heavier than bass, same shape the existing
  // 'Bass Boost' preset and native BASS_BOOST_SUB_BASS_EXTRA_MB/
  // BASS_BOOST_BASS_EXTRA_MB constants already use). Kept well inside the
  // ±12dB slider range and the native ceiling so headroom is preserved
  // even when layered on top of an already-boosted manual curve.
  //
  // WHY THIS APPROACH (not a native bassBoostIntensity parameter): the
  // native side (AurumAudioEffects.kt) already exposes
  // android.media.audiofx.BassBoost.setStrength() internally, but only
  // ever drives it from Premium Sound's own internal fade fraction —
  // there is no existing MethodChannel parameter for a user-controllable
  // bass strength, and adding one would mean touching native Kotlin AND
  // every other call site of applyAudioEffects() across the app to keep
  // them all passing a correct value, which is far riskier to get right
  // than reusing a pipeline that's already fully wired end to end. The
  // existing, already-proven-safe path this screen DOES have full
  // control over is bandGainsDb — the same 10 values already flowing
  // through applyAudioEffects() into the native EQ, which already
  // double-clamps (K_CAP ceiling, then the device's real bandLevelRange)
  // and arms the limiter whenever bass gain is added (see _ap2/_ap3 in
  // AurumAudioEffects.kt). Scaling an additive low-frequency curve into
  // that existing, already-safe pipeline is the smallest technically
  // correct implementation available without native changes, and — since
  // it's plain EQ band gain, not a second parallel effect — it can never
  // go stale relative to what SettingsPlayerScreen's own
  // Bass Boost/Volume Normalization toggles send, because every call
  // site already sends bandGainsDb as part of the same call.
  //
  // "Must not overwrite manual EQ": _effectiveBandGains() below always
  // starts from the user's real _values (their 10-band edits or preset,
  // whichever they last set) and ADDS the bass curve on top only for
  // bands 0-1 (32Hz/64Hz) — it never replaces _values itself, so turning
  // Bass Boost back to 0% always returns exactly to the user's own curve,
  // and a manual edit to any band (including 0/1) after setting Bass
  // Boost simply becomes the new base that the same percentage is added
  // on top of, same as any additive layer should behave.
  static const double _kBassBoostSubBassMaxDb = 4.0;
  static const double _kBassBoostBassMaxDb = 3.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _valuesNotifier.dispose();
    _presetNotifier.dispose();
    _bassBoostNotifier.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    _presetNotifier.value = p.getString('eq_preset') ?? 'Flat';
    _valuesNotifier.value = List.generate(10, (i) => p.getDouble('eq_band_$i') ?? 0.0);
    _bassBoostNotifier.value = (p.getDouble('eq_bass_boost_percent') ?? 0.0).clamp(0.0, 100.0);
    setState(() => _loaded = true);
  }

  /// The 10 band values actually sent to the native engine — the user's
  /// real _values with the Bass Boost percentage additively layered onto
  /// bands 0-1 only. See _kBassBoostSubBassMaxDb's doc comment above for
  /// why this never overwrites _values itself.
  List<double> _effectiveBandGains() {
    final values = _values;
    final percent = _bassBoostPercent;
    if (percent <= 0) return values;
    final fraction = percent / 100.0;
    final out = List<double>.from(values);
    out[0] = (out[0] + _kBassBoostSubBassMaxDb * fraction).clamp(-12.0, 12.0);
    out[1] = (out[1] + _kBassBoostBassMaxDb * fraction).clamp(-12.0, 12.0);
    return out;
  }

  Future<void> _saveValues() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('eq_preset', _selectedPreset);
    final values = _values;
    for (int i = 0; i < 10; i++) {
      await p.setDouble('eq_band_$i', values[i]);
    }
    await p.setDouble('eq_bass_boost_percent', _bassBoostPercent);
    // Bass Boost (on/off toggle) / Volume Normalization toggles live in
    // SettingsPlayerScreen's state, not here — read the persisted values
    // fresh so a custom EQ curve edit doesn't accidentally clobber them.
    final bassBoostToggle = p.getBool('bass_boost') ?? false;
    final volNorm = p.getBool('volume_normalization') ?? false;
    await widget.audioEngine?.applyAudioEffects(
      bassBoost: bassBoostToggle,
      volumeNormalization: volNorm,
      bandGainsDb: _effectiveBandGains(),
    );
  }

  void _applyPreset(String name) {
    AurumHaptics.selection();
    _presetNotifier.value = name;
    _valuesNotifier.value = List<double>.from(_presets[name]!);
    _saveValues();
  }

  void _resetAll() {
    AurumHaptics.light();
    _bassBoostNotifier.value = 0.0;
    _applyPreset('Flat');
  }

  void _onBassBoostChanged(double v) {
    _bassBoostNotifier.value = v;
  }

  void _onBandChanged(int i, double v) {
    // Mutate a fresh list (not in place) so ValueNotifier's identity
    // check still fires a notification, then push the single changed
    // value back.
    final next = List<double>.from(_valuesNotifier.value);
    next[i] = v;
    _valuesNotifier.value = next;
    if (_presetNotifier.value != 'Custom') _presetNotifier.value = 'Custom';
  }

  void _openPresetSheet(BuildContext context) {
    AurumHaptics.light();
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) => _PresetSheet(
        presets: _presets.keys.toList(),
        selected: _selectedPreset,
        onSelect: (name) {
          Navigator.pop(context);
          _applyPreset(name);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (!_loaded) {
      // Brief loading state while the first SharedPreferences read
      // resolves — same data source _load() always used, just an
      // explicit frame for it instead of showing default/zeroed values
      // for a flash before the real ones arrive.
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        appBar: AppBar(
          backgroundColor: AurumTheme.bgOf(context),
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                color: AurumTheme.textPrimaryOf(context), size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(l10n.spEqualizerTitle,
              style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18, fontWeight: FontWeight.w600)),
        ),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              color: AurumTheme.textPrimaryOf(context), size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(l10n.spEqualizerTitle,
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 18, fontWeight: FontWeight.w600)),
        actions: [
          // Subtle utility action, not a filled button — matches the
          // spec's "Reset should feel like a subtle utility action, not
          // unnecessarily large or button-like".
          TextButton(
            onPressed: _resetAll,
            child: Text(l10n.spEqReset,
                style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 14)),
          ),
        ],
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // ── PRESET (compact selector) ──
          // Only this row rebuilds when the preset name changes (e.g. a
          // band drag flips it to "Custom") — everything else below is
          // untouched by that change.
          _sectionLabel(l10n.spEqPresets),
          ValueListenableBuilder<String>(
            valueListenable: _presetNotifier,
            builder: (context, preset, _) => _PresetSelector(
              selected: preset,
              onTap: () => _openPresetSheet(context),
            ),
          ),

          const SizedBox(height: 22),

          // ── BASS BOOST ──
          // Only this card rebuilds while the Bass Boost slider is
          // dragged — the 10-band list and curve never repaint for it.
          _sectionLabel('BASS BOOST'),
          ValueListenableBuilder<double>(
            valueListenable: _bassBoostNotifier,
            builder: (context, percent, _) => _BassBoostCard(
              percent: percent,
              onChanged: _onBassBoostChanged,
              onChangeEnd: (_) => _saveValues(),
            ),
          ),

          const SizedBox(height: 22),

          // ── EQ RESPONSE VISUALIZATION ──
          // Only the curve (a single lightweight CustomPaint) rebuilds
          // when any band value OR the bass boost percentage changes —
          // combining both notifiers with Listenable.merge so it stays
          // accurate to what's actually being sent to the engine without
          // needing its own separate state copy.
          _sectionLabel(l10n.spEq10Band),
          ListenableBuilder(
            listenable: Listenable.merge([_valuesNotifier, _bassBoostNotifier]),
            builder: (context, _) => _EqResponseGraph(
              bandFreqsHz: _bandFreqsHz,
              values: _effectiveBandGains(),
              // Dragging a node edits the user's real band value (same
              // path _onBandChanged/_saveValues already use for the row
              // sliders below) — NOT the bass-boost-inflated display
              // value above. The graph shows the effective (bass-boost-
              // included) curve so it's an honest preview of what's
              // actually being sent to the engine, but a drag always
              // writes back to the same underlying _values the sliders
              // edit, so Bass Boost's contribution is never accidentally
              // baked into a manual band value.
              onDragBand: _onBandChanged,
              onDragEnd: (_) => _saveValues(),
            ),
          ),

          const SizedBox(height: 10),

          // ── BAND CONTROLS ──
          // Each row listens only to the shared values list (a single
          // ValueListenableBuilder covering all 10 rows) — still far
          // cheaper than the old design since this whole block no longer
          // sits inside the same setState as the preset card, bass boost
          // card, and curve above.
          ValueListenableBuilder<List<double>>(
            valueListenable: _valuesNotifier,
            builder: (context, values, _) => _EqBandList(
              bands: _bands,
              values: values,
              onChanged: _onBandChanged,
              onChangeEnd: (_) => _saveValues(),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Compact preset selector row — tapping opens _PresetSheet. Replaces the
// old full-width Wrap of pills with a single, calmer row that still shows
// the active preset name at a glance.
// ─────────────────────────────────────────────────────────────────────────
class _PresetSelector extends StatelessWidget {
  final String selected;
  final VoidCallback onTap;
  const _PresetSelector({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      scaleAmount: 0.98,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selected,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded,
                color: AurumTheme.textMutedOf(context), size: 20),
          ],
        ),
      ),
    );
  }
}

// Bottom sheet listing every existing preset (same table, same names) —
// purely a presentation change from the old inline Wrap of pills.
class _PresetSheet extends StatelessWidget {
  final List<String> presets;
  final String selected;
  final ValueChanged<String> onSelect;
  const _PresetSheet({
    required this.presets,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AurumTheme.dividerOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
              child: Row(
                children: [
                  Text('PRESET',
                      style: TextStyle(
                          color: AurumTheme.accentOf(context),
                          fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            ...presets.map((name) {
              final sel = name == selected;
              return InkWell(
                onTap: () => onSelect(name),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(name,
                            style: TextStyle(
                              color: sel ? AurumTheme.accentOf(context) : AurumTheme.textPrimaryOf(context),
                              fontSize: 15,
                              fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                            )),
                      ),
                      if (sel)
                        Icon(Icons.check_rounded, color: AurumTheme.accentOf(context), size: 18),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Bass Boost — single refined slider, 0-100%.
// ─────────────────────────────────────────────────────────────────────────
class _BassBoostCard extends StatelessWidget {
  final double percent;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  const _BassBoostCard({
    required this.percent,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Add extra low-end punch',
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 12.5,
                  ),
                ),
              ),
              Text(
                '${percent.round()}%',
                style: TextStyle(
                  color: percent > 0 ? accent : AurumTheme.textMutedOf(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 1),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: accent,
              inactiveTrackColor: AurumTheme.dividerOf(context),
              thumbColor: accent,
              overlayColor: accent.withOpacity(0.12),
            ),
            child: Slider(
              value: percent,
              min: 0, max: 100,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// EQ response visualization — a lightweight CustomPainter drawing the
// ACTUAL current band gains as a smooth curve over a log-frequency axis
// (32Hz-16kHz) and a ±12dB grid. No decorative/fake curve — every point
// is derived directly from `values`, the same array being sent to the
// native engine. RepaintBoundary + a tight shouldRepaint keeps this cheap
// even though it redraws on every band-slider drag.
//
// Interactive: dragging near a node updates that band's real value via
// onDragBand — same callback/persistence path a manual slider drag
// already uses (EqualizerScreenState._onBandChanged → _saveValues()), so
// dragging on the curve and dragging the matching row slider are two
// input paths into the exact same state, never a separate shadow value.
// ─────────────────────────────────────────────────────────────────────────
class _EqResponseGraph extends StatefulWidget {
  final List<int> bandFreqsHz;
  final List<double> values;
  final void Function(int index, double value)? onDragBand;
  final void Function(int index)? onDragEnd;
  const _EqResponseGraph({
    required this.bandFreqsHz,
    required this.values,
    this.onDragBand,
    this.onDragEnd,
  });

  @override
  State<_EqResponseGraph> createState() => _EqResponseGraphState();
}

class _EqResponseGraphState extends State<_EqResponseGraph> {
  int? _activeBand;

  static const double _minDb = -12;
  static const double _maxDb = 12;

  double _xFor(int freqHz, double width) {
    final minLog = math.log(32);
    final maxLog = math.log(16000);
    final t = (math.log(freqHz) - minLog) / (maxLog - minLog);
    return t.clamp(0.0, 1.0) * width;
  }

  /// Nearest band index to a horizontal touch position, so a drag
  /// anywhere reasonably close to a node grabs that band rather than
  /// requiring a pixel-perfect hit — small touch targets on a dense
  /// 10-node graph would otherwise be hard to grab accurately.
  int _nearestBandIndex(double touchX, double width) {
    int best = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < widget.bandFreqsHz.length; i++) {
      final d = (_xFor(widget.bandFreqsHz[i], width) - touchX).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  double _dbForY(double y, double height) {
    final t = 1.0 - (y / height);
    return (_minDb + t.clamp(0.0, 1.0) * (_maxDb - _minDb)).clamp(_minDb, _maxDb);
  }

  void _handleTouch(Offset local, Size size, {required bool isEnd}) {
    if (widget.onDragBand == null) return;
    if (isEnd) {
      if (_activeBand != null) widget.onDragEnd?.call(_activeBand!);
      setState(() => _activeBand = null);
      return;
    }
    final band = _activeBand ?? _nearestBandIndex(local.dx, size.width);
    final db = _dbForY(local.dy, size.height);
    setState(() => _activeBand = band);
    widget.onDragBand!(band, (db * 2).round() / 2); // snap to 0.5dB, matches row sliders' divisions
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = AurumTheme.accentOf(context);
    return RepaintBoundary(
      child: Container(
        height: 120,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: widget.onDragBand == null
                  ? null
                  : (d) => _handleTouch(d.localPosition, size, isEnd: false),
              onPanUpdate: widget.onDragBand == null
                  ? null
                  : (d) => _handleTouch(d.localPosition, size, isEnd: false),
              onPanEnd: widget.onDragBand == null
                  ? null
                  : (_) => _handleTouch(Offset.zero, size, isEnd: true),
              child: CustomPaint(
                size: Size.infinite,
                painter: _EqCurvePainter(
                  freqs: widget.bandFreqsHz,
                  values: widget.values,
                  gridColor: AurumTheme.dividerOf(context),
                  curveColor: accent,
                  isDark: isDark,
                  activeBand: _activeBand,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EqCurvePainter extends CustomPainter {
  final List<int> freqs;
  final List<double> values;
  final Color gridColor;
  final Color curveColor;
  final bool isDark;
  final int? activeBand;

  _EqCurvePainter({
    required this.freqs,
    required this.values,
    required this.gridColor,
    required this.curveColor,
    required this.isDark,
    this.activeBand,
  });

  static const double _minDb = -12;
  static const double _maxDb = 12;

  double _xFor(int freqHz, double width) {
    // Log-scaled x-axis: 32Hz-16kHz spans a 9-octave range (log2(16000/32)),
    // matching how real graphic EQs lay out frequency, not linear Hz.
    final minLog = math.log(32);
    final maxLog = math.log(16000);
    final t = (math.log(freqHz) - minLog) / (maxLog - minLog);
    return t.clamp(0.0, 1.0) * width;
  }

  double _yFor(double db, double height) {
    final t = (db - _minDb) / (_maxDb - _minDb);
    return height - t.clamp(0.0, 1.0) * height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Grid: 0dB center line (slightly stronger) + two subtle guide lines
    // above/below. Kept minimal per spec — no dense grid, no labels
    // cluttering the curve itself.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final zeroPaint = Paint()
      ..color = gridColor.withOpacity(isDark ? 0.9 : 1.0)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), zeroPaint);
    canvas.drawLine(Offset(0, h * 0.15), Offset(w, h * 0.15), gridPaint);
    canvas.drawLine(Offset(0, h * 0.85), Offset(w, h * 0.85), gridPaint);

    // Build the curve through each band's actual current value — this IS
    // the real EQ state, not a decorative approximation.
    final points = <Offset>[];
    for (int i = 0; i < freqs.length && i < values.length; i++) {
      points.add(Offset(_xFor(freqs[i], w), _yFor(values[i], h)));
    }
    if (points.isEmpty) return;

    // Smooth the polyline through the band points with a simple Catmull-
    // Rom-style spline so it reads as a continuous frequency response
    // rather than a jagged connect-the-dots line — still 100% derived
    // from the real values above, purely a rendering smoothing pass.
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i == 0 ? i : i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = points[i + 2 < points.length ? i + 2 : i + 1];
      final cp1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
      final cp2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }

    final curvePaint = Paint()
      ..color = curveColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, curvePaint);

    // Node dots at each band's real position — doubles as the visual
    // anchor for the "which frequency am I looking at" read. The node
    // currently being dragged (if any) draws slightly larger with a soft
    // halo ring so there's clear feedback on which one is active —
    // still just two cheap drawCircle calls, no gradients/glow.
    final nodePaint = Paint()..color = curveColor;
    for (int i = 0; i < points.length; i++) {
      final isActive = i == activeBand;
      if (isActive) {
        final haloPaint = Paint()..color = curveColor.withOpacity(0.18);
        canvas.drawCircle(points[i], 8, haloPaint);
      }
      canvas.drawCircle(points[i], isActive ? 3.5 : 2.5, nodePaint);
    }
  }

  @override
  bool shouldRepaint(_EqCurvePainter old) =>
      !_listEquals(old.values, values) ||
      old.gridColor != gridColor ||
      old.curveColor != curveColor ||
      old.isDark != isDark ||
      old.activeBand != activeBand;

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Compact 10-band list — same bands/frequencies/±12dB range/persistence
// as before, laid out tighter with precise one-decimal dB formatting.
// ─────────────────────────────────────────────────────────────────────────
class _EqBandList extends StatelessWidget {
  final List<String> bands;
  final List<double> values;
  final void Function(int index, double value) onChanged;
  final void Function(double value) onChangeEnd;
  const _EqBandList({
    required this.bands,
    required this.values,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Column(
        children: List.generate(bands.length, (i) {
          final v = values[i];
          return SizedBox(
            height: 34,
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Text(
                    bands[i],
                    style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11.5),
                    textAlign: TextAlign.right,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 1),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: v == 0 ? AurumTheme.textMutedOf(context) : accent,
                      inactiveTrackColor: AurumTheme.dividerOf(context),
                      thumbColor: v == 0 ? AurumTheme.textMutedOf(context) : accent,
                      overlayColor: accent.withOpacity(0.12),
                    ),
                    child: Slider(
                      value: v,
                      min: -12, max: 12, divisions: 48, // 0.5dB steps for finer control
                      onChanged: (val) => onChanged(i, val),
                      onChangeEnd: onChangeEnd,
                    ),
                  ),
                ),
                SizedBox(
                  width: 50,
                  child: Text(
                    '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: v == 0 ? AurumTheme.textMutedOf(context) : accent,
                      fontSize: 11, fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
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

/// Maps the stored preference key ('auto'/'always'/'hidden') to its
/// localized display label for the dropdown, and back — AudioPrefs and
/// SharedPreferences always store the stable English key regardless of
/// display language, same as _streamQuality's 'Auto'/'High' keys elsewhere
/// in this file.
String _castIconVisibilityLabel(AppLocalizations l10n, String key) {
  switch (key) {
    case 'always':
      return l10n.spCastIconAlways;
    case 'hidden':
      return l10n.spCastIconHidden;
    default:
      return l10n.spCastIconAuto;
  }
}

String _castIconVisibilityKeyFromLabel(AppLocalizations l10n, String label) {
  if (label == l10n.spCastIconAlways) return 'always';
  if (label == l10n.spCastIconHidden) return 'hidden';
  return 'auto';
}

/// Same stable-key / localized-label split as _castIconVisibilityLabel
/// above — 'off'/'light'/'strong' are stored, the dropdown shows the
/// localized text.
String _hapticIntensityLabel(AppLocalizations l10n, String key) {
  switch (key) {
    case 'off':
      return l10n.spHapticOff;
    case 'strong':
      return l10n.spHapticStrong;
    default:
      return l10n.spHapticLight;
  }
}

String _hapticIntensityKeyFromLabel(AppLocalizations l10n, String label) {
  if (label == l10n.spHapticOff) return 'off';
  if (label == l10n.spHapticStrong) return 'strong';
  return 'light';
}

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
      transitionsBuilder: (context, animation, __, child) {
        final tween = Tween(begin: const Offset(1.0, 0.0), end: Offset.zero)
            .chain(CurveTween(curve: Curves.easeOutCubic));
        return ColoredBox(
          color: AurumTheme.bgOf(context),
          child: SlideTransition(position: animation.drive(tween), child: child),
        );
      },
      transitionDuration: const Duration(milliseconds: 280),
      // FIX ("back feels stuck/not smooth"): matched to the forward
      // duration above — was 250ms vs 280ms open.
      reverseTransitionDuration: const Duration(milliseconds: 280),
    );
