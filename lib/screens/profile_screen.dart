import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:aurum_music/widgets/aurum_morph_loader.dart';
import 'dart:math' as math;
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/aurum_image_cache.dart';
import '../theme/aurum_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/premium_provider.dart';
import '../services/sync_service.dart';
import '../services/audio_prefs.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  // Ambient background — same lightweight gold-glow + drifting-particle
  // treatment as PremiumScreen, reused here so the whole app's "premium"
  // pages feel like one family instead of profile looking like a
  // different, flatter screen. Gated on the same animations toggle for
  // low-end devices (see PremiumScreen for why).
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;
  late final AnimationController _particleCtrl;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: AurumMotion.durationOrZero(AurumMotion.long2),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    WidgetsBinding.instance.addObserver(this);

    final animsOn = AudioPrefs.enableAnimationsNotifier.value;

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOutSine);

    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8000),
    );

    if (animsOn) {
      _glowCtrl.repeat(reverse: true);
      _particleCtrl.repeat();
    } else {
      _glowCtrl.value = 0.5;
      _particleCtrl.value = 0.0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!AudioPrefs.enableAnimationsNotifier.value) return;
      if (!_glowCtrl.isAnimating) _glowCtrl.repeat(reverse: true);
      if (!_particleCtrl.isAnimating) _particleCtrl.repeat();
    } else {
      _glowCtrl.stop();
      _particleCtrl.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fadeCtrl.dispose();
    _glowCtrl.dispose();
    _particleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      // Was flat Color(0xFF060608) (near-pure-black) — switched to the
      // app's real dark-theme background so profile matches the rest of
      // Aurum's navy-violet dark surfaces instead of reading as its own
      // separate, darker "AMOLED-black" screen.
      backgroundColor: AurumTheme.darkBg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withOpacity(0.35),
            ),
            child: const Icon(Icons.arrow_back_ios_rounded,
                color: Colors.white, size: 16),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(l10n.prProfile,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: Stack(
        children: [
          // ── Drifting gold particles (lightweight CustomPainter, 18 dots) ──
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _particleCtrl,
              builder: (_, __) => CustomPaint(
                size: Size.infinite,
                painter: _ProfileParticlePainter(_particleCtrl.value),
              ),
            ),
          ),
          // ── Soft breathing glow at the top — kept very restrained (low
          // peak opacity, wide soft radius) so it reads as ambient depth
          // behind the hero photo, not a neon accent sitting on top of it. ──
          AnimatedBuilder(
            animation: _glow,
            builder: (_, __) => Positioned(
              top: -80,
              left: 0,
              right: 0,
              child: Container(
                height: 260,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      AurumTheme.gold.withOpacity(0.06 + _glow.value * 0.03),
                      Colors.transparent,
                    ],
                    radius: 0.9,
                  ),
                ),
              ),
            ),
          ),
          FadeTransition(
            opacity: _fadeAnim,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // ── Hero Header ──
                  const _ProfileHero(),

                  // ── Premium Benefits Card ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    child: _PremiumCard(),
                  ),

                  // ── Account / Sign-in Card ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: _AccountCard(),
                  ),

                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ambient particle painter — identical lightweight approach to PremiumScreen's
// _ParticlePainter: 18 fixed dots (seeded, so no per-frame allocation),
// drifting slowly upward with a gentle sine-based twinkle.
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileParticlePainter extends CustomPainter {
  final double t;
  static final _rng = math.Random(42);
  // 12 (not 18) — fewer, smaller, dimmer dots than PremiumScreen's paywall
  // background. That screen is a one-off sales moment where a livelier
  // effect is fine; profile is a screen people sit on, so it stays closer
  // to "barely-there texture" than "effect" — professional, not neon.
  static final _particles = List.generate(12, (i) => [
    _rng.nextDouble(),
    _rng.nextDouble(),
    _rng.nextDouble(),
    _rng.nextDouble(),
    _rng.nextDouble(),
  ]);
  static final _paints = List.generate(12, (_) => Paint());

  _ProfileParticlePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < _particles.length; i++) {
      final p = _particles[i];
      final x = p[0] * size.width;
      final y = ((p[1] + t * p[2] * 0.3) % 1.0) * size.height;
      final radius = 0.6 + p[3] * 1.2;
      final opacity = (0.03 + p[4] * 0.06) *
          (0.5 + 0.5 * math.sin(t * math.pi * 2 * (0.5 + p[2])));

      _paints[i].color = AurumTheme.gold.withOpacity(opacity);
      canvas.drawCircle(Offset(x, y), radius, _paints[i]);
    }
  }

  @override
  bool shouldRepaint(_ProfileParticlePainter old) => old.t != t;
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero Header — Google photo blurred bg + name + email + gold badge
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileHero extends StatelessWidget {
  const _ProfileHero();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final auth = context.watch<AuthProvider>();
    final avatarUrl = auth.avatarUrl;
    final name = auth.displayName ?? l10n.prAurumListener;
    final email = auth.email;

    return SizedBox(
      height: 310,
      child: Stack(fit: StackFit.expand, children: [
        // ── Blurred bg ──
        avatarUrl != null
            ? ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: CachedNetworkImage(
                  imageUrl: avatarUrl,
                  cacheManager: AurumImageCache(),
                  fit: BoxFit.cover,
                  // LOW-END DEVICE FIX (2GB RAM): heavily blurred (28σ)
                  // full-screen background — a small decode target looks
                  // identical once blurred this hard, so there's no
                  // reason to decode a Google profile photo at its native
                  // resolution just to blur away all its detail.
                  memCacheWidth: 200,
                  // FIX: same white/grey flash issue as elsewhere in the
                  // app — without a `placeholder`, CachedNetworkImage's
                  // own flat grey/white box would show across this whole
                  // 310px hero while the Google profile photo is still
                  // downloading. Reusing the themed gradient background
                  // keeps this looking intentional instead of broken.
                  placeholder: (_, __) => _gradientBg(),
                  errorWidget: (_, __, ___) => _gradientBg(),
                ),
              )
            : _gradientBg(),

        // ── Scrim ──
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.25),
                Colors.black.withOpacity(0.55),
                AurumTheme.bgOf(context),
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),

        // ── Content ──
        SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Avatar
              Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AurumTheme.goldGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold.withOpacity(0.45),
                      blurRadius: 22,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(3),
                child: ClipOval(
                  child: avatarUrl != null
                      ? CachedNetworkImage(
                          imageUrl: avatarUrl,
                          cacheManager: AurumImageCache(),
                          fit: BoxFit.cover,
                          // LOW-END DEVICE FIX (2GB RAM): 100x100 display
                          // circle, capped to 2x for crisp high-DPI
                          // rendering instead of decoding the source
                          // photo (Google avatars can come back at
                          // several hundred px) at full resolution.
                          memCacheWidth: 200,
                          memCacheHeight: 200,
                          placeholder: (_, __) => Container(
                            color: AurumTheme.bgCardOf(context),
                            child: const Icon(Icons.person_rounded,
                                color: AurumTheme.gold, size: 44),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            color: AurumTheme.bgCardOf(context),
                            child: const Icon(Icons.person_rounded,
                                color: AurumTheme.gold, size: 44),
                          ),
                        )
                      : Container(
                          color: AurumTheme.bgCardOf(context),
                          child: const Icon(Icons.person_rounded,
                              color: AurumTheme.gold, size: 44),
                        ),
                ),
              ),
              const SizedBox(height: 12),

              // Name
              Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              if (email != null) ...[
                const SizedBox(height: 4),
                Text(
                  email,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.65),
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 10),

              // Gold badge — only shown for premium users
              Builder(builder: (context) {
                final isPremium = context.watch<PremiumProvider>().isPremium;
                if (!isPremium) return const SizedBox(height: 22);
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: AurumTheme.goldGradient,
                    ),
                    child: Text(
                      l10n.prPremiumBadge,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                ]);
              }),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _gradientBg() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AurumTheme.darkBgElevated, AurumTheme.darkBgSurface, AurumTheme.darkBg],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Benefits Card
// ─────────────────────────────────────────────────────────────────────────────

class _PremiumCard extends StatelessWidget {
  const _PremiumCard();

  static List<(IconData, String, String)> _benefits(AppLocalizations l10n) => [
    (Icons.sync_rounded,           l10n.prBenefitSyncTitle,     l10n.prBenefitSyncSub),
    (Icons.block_rounded,          l10n.prBenefitAdFreeTitle,   l10n.prBenefitAdFreeSub),
    (Icons.high_quality_rounded,   l10n.prBenefitQualityTitle,  l10n.prBenefitQualitySub),
    (Icons.download_done_rounded,  l10n.prBenefitOfflineTitle,  l10n.prBenefitOfflineSub),
    (Icons.recommend_rounded,      l10n.prBenefitRecsTitle,     l10n.prBenefitRecsSub),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Payment gate removed for now — every benefit below is free with a
    // Google account. Left PremiumProvider/isPremium wiring untouched
    // elsewhere so it's trivial to decide later which of these (if any)
    // move back behind a real paywall; this screen just always renders
    // the "unlocked" visual state in the meantime.
    const isPremium = true;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AurumTheme.goldDark.withOpacity(0.22),
            AurumTheme.gold.withOpacity(0.08),
          ],
        ),
        border: Border.all(color: AurumTheme.gold.withOpacity(0.28), width: 0.9),
      ),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AurumTheme.goldGradient,
                ),
                child: const Icon(Icons.workspace_premium_rounded,
                    color: Colors.black, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.prAurumPremiumPlain,
                      style: TextStyle(
                        color: AurumTheme.gold,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      )),
                  Text(
                    isPremium ? l10n.prAllFeaturesUnlocked : l10n.prUpgradeToUnlock,
                    style: TextStyle(
                      color: AurumTheme.textMutedOf(context),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: isPremium
                      ? AurumTheme.gold.withOpacity(0.15)
                      : Colors.white.withOpacity(0.07),
                  border: Border.all(
                    color: isPremium
                        ? AurumTheme.gold.withOpacity(0.4)
                        : AurumTheme.dividerOf(context),
                  ),
                ),
                child: Text(
                  isPremium ? l10n.prActive : l10n.prFree,
                  style: TextStyle(
                    color: isPremium
                        ? AurumTheme.gold
                        : AurumTheme.textMutedOf(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ]),
          ),

          Divider(height: 1, color: AurumTheme.gold.withOpacity(0.12)),

          // Benefits list
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              children: _benefits(l10n).map((b) => _BenefitRow(
                icon: b.$1,
                title: b.$2,
                subtitle: b.$3,
                active: isPremium,
              )).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;
  const _BenefitRow({required this.icon, required this.title, required this.subtitle, this.active = true});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AurumTheme.gold.withOpacity(active ? 0.12 : 0.05),
          ),
          child: Icon(icon, color: active ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                    color: active ? AurumTheme.textPrimaryOf(context) : AurumTheme.textMutedOf(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  )),
              Text(subtitle,
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 11.5,
                  )),
            ],
          ),
        ),
        Icon(
          active ? Icons.check_circle_rounded : Icons.lock_rounded,
          color: active ? AurumTheme.gold : AurumTheme.textMutedOf(context).withOpacity(0.5),
          size: 18,
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Account Card — Sign in / signed-in state with sync + sign out
// ─────────────────────────────────────────────────────────────────────────────

class _AccountCard extends StatefulWidget {
  const _AccountCard();
  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  bool _syncing = false;

  Future<void> _handleSignIn(AuthProvider auth) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await auth.signInWithGoogle();
    if (!mounted) return;
    if (ok) {
      // Cloud sync is sign-in-gated only, not payment-gated (see
      // SyncService._canSync / main_shell.dart's foreground sync) — this
      // used to skip syncAll() entirely for non-premium users ("Phase 3
      // — Cloud sync is premium-only"), which is why library data only
      // ever showed up after 2-3 sign-out/sign-in cycles: the login path
      // itself never synced anything for a free account, and data only
      // arrived later by accident, via the next app-resume foreground
      // sync. Every signed-in user gets a real sync right here now.
      setState(() => _syncing = true);
      try {
        await SyncService.instance.syncAll(
          playlists: context.read<PlaylistProvider>(),
          followedArtists: context.read<FollowedArtistsProvider>(),
          followedAlbums: context.read<FollowedAlbumsProvider>(),
          favorites: context.read<FavoritesProvider>(),
          history: context.read<RecentlyPlayedProvider>(),
        );
      } finally {
        if (mounted) setState(() => _syncing = false);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.prSignedInSynced),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
      }
    } else if (auth.lastError != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(auth.lastError!),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  Future<void> _handleSignOut(AuthProvider auth) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        title: Text(l10n.prSignOutTitle,
            style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: Text(
          l10n.prSignOutBody,
          style: TextStyle(color: AurumTheme.textSecondaryOf(context)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.prCancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.prSignOut,
                style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _signOutAndWipe(auth);
  }

  /// Signs out of Google/Supabase, then clears every account-scoped local
  /// provider (Liked Songs, Playlists, Followed Artists, History) so the
  /// device goes back to a clean slate — matching what the confirmation
  /// dialog above promises. Signing back in (same account or a different
  /// one) pulls fresh data from Supabase via SyncService instead of ever
  /// mixing with a previous account's leftovers.
  //
  // Deliberately NOT cleared: Downloads (actual audio files on disk —
  // deleting those without a separate, explicit "Delete downloads too?"
  // confirmation would be a surprising, destructive side effect of what
  // the user thinks is just a sign-out) and device-level preferences
  // (theme, equalizer, sleep timer, etc.) which belong to the device, not
  // the account.
  Future<void> _signOutAndWipe(AuthProvider auth) async {
    final l10n = AppLocalizations.of(context)!;
    AurumHaptics.medium();

    // Premium, top-level feel: a brief centered loader overlay while the
    // wipe runs (this is all local Hive box clears, so it's fast — but a
    // frozen UI with no feedback reads as broken, not premium).
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withOpacity(0.55),
        builder: (_) => const Center(
          child: AurumMorphLoader(size: 48),
        ),
      );
    }

    try {
      await auth.signOut();
      if (!mounted) return;
      await Future.wait([
        context.read<FavoritesProvider>().clearAll(),
        context.read<PlaylistProvider>().clearAll(),
        context.read<FollowedArtistsProvider>().clearAll(),
        context.read<FollowedAlbumsProvider>().clearAll(),
        context.read<RecentlyPlayedProvider>().clearHistory(),
      ]);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop(); // close loader
    }

    if (mounted) {
      AurumHaptics.light();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.prSignedOutCleared),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AurumTheme.bgCardOf(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AurumTheme.dividerOf(context), width: 0.8),
          ),
          child: auth.isSignedIn
              ? Row(children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AurumTheme.gold.withOpacity(0.5), width: 2),
                    ),
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: AurumTheme.gold.withOpacity(0.15),
                      backgroundImage: auth.avatarUrl != null
                          ? NetworkImage(auth.avatarUrl!)
                          : null,
                      child: auth.avatarUrl == null
                          ? const Icon(Icons.person_rounded,
                              color: AurumTheme.gold)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          auth.displayName ?? l10n.prSignedIn,
                          style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (auth.email != null)
                          Text(
                            auth.email!,
                            style: TextStyle(
                                color: AurumTheme.textMutedOf(context),
                                fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (_syncing)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(l10n.prSyncingLibrary,
                                style: TextStyle(
                                    color: AurumTheme.gold, fontSize: 11)),
                          ),
                      ],
                    ),
                  ),
                  _syncing
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: Center(child: AurumM3Loader(width: 18, height: 2)),
                        )
                      : IconButton(
                          icon: Icon(Icons.logout_rounded,
                              color: AurumTheme.textMutedOf(context),
                              size: 20),
                          onPressed: () => _handleSignOut(auth),
                        ),
                ])
              : Row(children: [
                  Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AurumTheme.bgElevatedOf(context),
                    ),
                    child: Icon(Icons.account_circle_outlined,
                        color: AurumTheme.textMutedOf(context), size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.prSyncLibraryTitle,
                            style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            )),
                        const SizedBox(height: 2),
                        Text(l10n.prSyncLibrarySubtitle,
                            style: TextStyle(
                              color: AurumTheme.textMutedOf(context),
                              fontSize: 12,
                            )),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  auth.isSigningIn || _syncing
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: Center(child: AurumM3Loader(width: 20, height: 2)),
                        )
                      : OutlinedButton.icon(
                          onPressed: () => _handleSignIn(auth),
                          icon: const Icon(Icons.g_mobiledata_rounded,
                              size: 20),
                          label: Text(l10n.prSignIn),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AurumTheme.gold,
                            side: const BorderSide(color: AurumTheme.gold),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                          ),
                        ),
                ]),
        );
      },
    );
  }
}
