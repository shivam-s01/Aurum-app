import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:aurum_music/widgets/aurum_morph_loader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/analytics_service.dart';
import '../services/aurum_image_cache.dart';
import '../theme/aurum_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/premium_provider.dart';
import '../services/sync_service.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/artwork_palette_cache.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';
import '../utils/aurum_transitions.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import 'liked_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Profile — redesigned.
//
//  • Hero gradient is tinted from the user's own avatar colors (same palette
//    extractor the players use), fading smoothly into the theme background.
//  • Left-aligned big avatar + name, Spotify-profile style.
//  • One stats strip (Liked / Playlists / Artists / Albums) with live counts.
//  • "Recently Played" shelf — tap to play.
//  • Compact membership card (chips instead of a long list).
//  • Sticky top bar that fades in a title once you scroll.
//  • No looping animations (no particles / breathing glow): one short staggered
//    entrance only, and fully off when animations are disabled — smoother and
//    lighter on low-end phones.
//  • Every colour comes from the active theme, so Light / Dark / AMOLED all work.
//  • All sign-in / sign-out / sync behaviour is unchanged.
// ─────────────────────────────────────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  static const int _sections = 5;

  late final AnimationController _enter;
  late final List<Animation<double>> _reveal;
  final ScrollController _scroll = ScrollController();
  final ValueNotifier<double> _barT = ValueNotifier<double>(0);

  bool _syncing = false;

  // Avatar-derived tint for the hero gradient.
  String? _tintUrl;
  Color? _tint;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.logScreen('Profile');

    _enter = AnimationController(
      vsync: this,
      duration: AurumMotion.durationOrZero(const Duration(milliseconds: 750)),
    );
    _reveal = List.generate(_sections, (i) {
      final start = (i * 0.12).clamp(0.0, 0.7);
      final end = (start + 0.45).clamp(0.0, 1.0);
      return CurvedAnimation(
        parent: _enter,
        curve: Interval(start, end, curve: Curves.easeOutCubic),
      );
    });
    _enter.forward();

    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _barT.value = ((_scroll.offset - 90) / 80).clamp(0.0, 1.0);
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    _scroll.dispose();
    _barT.dispose();
    super.dispose();
  }

  // ── Avatar tint ────────────────────────────────────────────────────────────

  void _ensureTint(String? url) {
    if (url == _tintUrl) return;
    _tintUrl = url;
    if (url == null || url.isEmpty) {
      _tint = null;
      return;
    }
    final cached = ArtworkPaletteCache.peek(url);
    if (cached != null) {
      _tint = cached.vibrant;
      return;
    }
    _tint = null;
    ArtworkPaletteCache.getFast(url).then((p) {
      if (!mounted || _tintUrl != url || p == null) return;
      setState(() => _tint = p.dominant);
    }).catchError((_) {});
  }

  // ── Account actions (logic unchanged from the previous screen) ─────────────

  Future<void> _runSync() async {
    await SyncService.instance.syncAll(
      playlists: context.read<PlaylistProvider>(),
      followedArtists: context.read<FollowedArtistsProvider>(),
      followedAlbums: context.read<FollowedAlbumsProvider>(),
      favorites: context.read<FavoritesProvider>(),
      history: context.read<RecentlyPlayedProvider>(),
    );
  }

  Future<void> _handleSignIn(AuthProvider auth) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await auth.signInWithGoogle();
    if (!mounted) return;
    if (ok) {
      // Cloud sync is sign-in-gated only, not payment-gated — every signed-in
      // user gets a real sync right here.
      setState(() => _syncing = true);
      try {
        await _runSync();
      } finally {
        if (mounted) setState(() => _syncing = false);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.prSignedInSynced),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
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

  Future<void> _handleManualSync() async {
    if (_syncing) return;
    AurumHaptics.light();
    setState(() => _syncing = true);
    try {
      await _runSync();
    } catch (_) {
      // Sync fails soft — SyncService already logs its own errors.
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    if (mounted) AurumHaptics.selection();
  }

  Future<void> _handleSignOut(AuthProvider auth) async {
    final l10n = AppLocalizations.of(context)!;
    AurumHaptics.light();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(l10n.prSignOutTitle,
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontWeight: FontWeight.w800)),
        content: Text(
          l10n.prSignOutBody,
          style: TextStyle(
              color: AurumTheme.textSecondaryOf(context), height: 1.4),
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

  /// Signs out, then clears every account-scoped local provider so the device
  /// goes back to a clean slate. Downloads and device preferences are
  /// deliberately kept (see the old implementation's note).
  Future<void> _signOutAndWipe(AuthProvider auth) async {
    final l10n = AppLocalizations.of(context)!;
    AurumHaptics.medium();

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withOpacity(0.55),
        builder: (_) => const Center(
          child: AurumMorphLoader(size: 48, contained: true),
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
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    if (mounted) {
      AurumHaptics.light();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.prSignedOutCleared),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  Widget _stagger(int i, Widget child) {
    final a = _reveal[i];
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
            .animate(a),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = AurumTheme.bgOf(context);
    final auth = context.watch<AuthProvider>();
    _ensureTint(auth.avatarUrl);

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: _stagger(
                  0,
                  _ProfileHero(
                    tint: _tint,
                    syncing: _syncing,
                    onSync: _handleManualSync,
                    onSignOut: () => _handleSignOut(auth),
                    onSignIn: () => _handleSignIn(auth),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _stagger(
                  1,
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: _StatsStrip(),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _stagger(2, const _RecentlyPlayedShelf()),
              ),
              SliverToBoxAdapter(
                child: _stagger(
                  3,
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 28, 20, 0),
                    child: _MembershipCard(),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 56)),
            ],
          ),
          _TopBar(progress: _barT),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sticky top bar — transparent over the hero, solid + titled once scrolled.
// ─────────────────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final ValueNotifier<double> progress;
  const _TopBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final top = MediaQuery.of(context).padding.top;
    final bg = AurumTheme.bgOf(context);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (context, t, _) => Container(
          height: top + 60,
          padding: EdgeInsets.only(top: top, left: 12, right: 20),
          decoration: BoxDecoration(
            color: bg.withOpacity(t),
            border: Border(
              bottom: BorderSide(
                color: AurumTheme.dividerOf(context).withOpacity(t * 0.7),
                width: 0.6,
              ),
            ),
          ),
          child: Row(
            children: [
              AurumPressable(
                onTap: () => Navigator.maybePop(context),
                scaleAmount: 0.92,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AurumTheme.bgCardOf(context)
                        .withOpacity(0.72 * (1 - t) + 0.0),
                  ),
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 17, color: AurumTheme.textPrimaryOf(context)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Opacity(
                  opacity: t,
                  child: Text(
                    l10n.prProfile,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero — avatar-tinted gradient, big avatar, name, email, badge, actions.
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileHero extends StatelessWidget {
  final Color? tint;
  final bool syncing;
  final VoidCallback onSync;
  final VoidCallback onSignOut;
  final VoidCallback onSignIn;

  const _ProfileHero({
    required this.tint,
    required this.syncing,
    required this.onSync,
    required this.onSignOut,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final auth = context.watch<AuthProvider>();
    final isPremium = context.watch<PremiumProvider>().isPremium;
    final accent = AurumTheme.accentOf(context);
    final bg = AurumTheme.bgOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final top = MediaQuery.of(context).padding.top;

    final base = tint ?? accent;
    final washTop =
        Color.alphaBlend(base.withOpacity(isDark ? 0.62 : 0.42), bg);
    final washMid =
        Color.alphaBlend(base.withOpacity(isDark ? 0.24 : 0.16), bg);

    final name = auth.displayName ?? l10n.prAurumListener;
    final email = auth.email;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      padding: EdgeInsets.fromLTRB(20, top + 76, 20, 26),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [washTop, washMid, bg],
          stops: const [0.0, 0.62, 1.0],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(url: auth.avatarUrl, glow: base),
          const SizedBox(height: 18),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 32,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.0,
            ),
          ),
          if (email != null) ...[
            const SizedBox(height: 6),
            Text(
              email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (isPremium) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: AurumTheme.accentGradientOf(context),
              ),
              child: Text(
                l10n.prPremiumBadge,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
          const SizedBox(height: 22),
          if (auth.isSignedIn)
            Row(
              children: [
                _SyncButton(syncing: syncing, onTap: onSync),
                const SizedBox(width: 12),
                _OutlinePill(
                  icon: Icons.logout_rounded,
                  label: l10n.prSignOut,
                  onTap: syncing ? null : onSignOut,
                ),
                if (syncing) ...[
                  const SizedBox(width: 14),
                  Flexible(
                    child: Text(
                      l10n.prSyncingLibrary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accent,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            )
          else
            _SignInCard(
              busy: auth.isSigningIn || syncing,
              onTap: onSignIn,
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final Color glow;
  const _Avatar({required this.url, required this.glow});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final card = AurumTheme.bgCardOf(context);
    final placeholder = Container(
      color: card,
      child: Icon(Icons.person_rounded, color: accent, size: 52),
    );

    return Container(
      width: 120,
      height: 120,
      padding: const EdgeInsets.all(3.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AurumTheme.accentGradientOf(context),
        boxShadow: [
          BoxShadow(
            color: glow.withOpacity(0.38),
            blurRadius: 32,
            spreadRadius: 1,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AurumTheme.bgOf(context), width: 3),
        ),
        child: ClipOval(
          child: (url != null && url!.isNotEmpty)
              ? CachedNetworkImage(
                  imageUrl: url!,
                  cacheManager: AurumImageCache(),
                  fit: BoxFit.cover,
                  // 2x of the 120dp circle is plenty; don't decode the
                  // full-size Google photo on low-RAM devices.
                  memCacheWidth: 260,
                  memCacheHeight: 260,
                  placeholder: (_, __) => placeholder,
                  errorWidget: (_, __, ___) => placeholder,
                )
              : placeholder,
        ),
      ),
    );
  }
}

class _SyncButton extends StatelessWidget {
  final bool syncing;
  final VoidCallback onTap;
  const _SyncButton({required this.syncing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.prSyncLibraryTitle,
      child: AurumPressable(
        onTap: syncing ? null : onTap,
        haptic: false,
        scaleAmount: 0.92,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AurumTheme.accentGradientOf(context),
            boxShadow: [
              BoxShadow(
                color: AurumTheme.accentOf(context).withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: syncing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor: AlwaysStoppedAnimation(Colors.black),
                    ),
                  )
                : const Icon(Icons.sync_rounded, color: Colors.black, size: 26),
          ),
        ),
      ),
    );
  }
}

class _OutlinePill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _OutlinePill({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = AurumTheme.textPrimaryOf(context);
    return AurumPressable(
      onTap: onTap,
      haptic: false,
      scaleAmount: 0.95,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: fg.withOpacity(0.32), width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignInCard extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _SignInCard({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context).withOpacity(0.85),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.prSyncLibraryTitle,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.prSyncLibrarySubtitle,
            style: TextStyle(
              color: AurumTheme.textSecondaryOf(context),
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          AurumPressable(
            onTap: busy ? null : onTap,
            scaleAmount: 0.97,
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: AurumTheme.accentGradientOf(context),
              ),
              child: busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: Center(child: AurumM3Loader(width: 22, height: 2)),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.g_mobiledata_rounded,
                            color: Colors.black, size: 28),
                        const SizedBox(width: 6),
                        Text(
                          l10n.prSignIn,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
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
// Stats strip — live counts, Liked is tappable.
// ─────────────────────────────────────────────────────────────────────────────

String _compact(int n) {
  if (n >= 1000000) {
    final v = (n / 1000000).toStringAsFixed(1);
    return '${v.endsWith('.0') ? v.substring(0, v.length - 2) : v}M';
  }
  if (n >= 1000) {
    final v = (n / 1000).toStringAsFixed(1);
    return '${v.endsWith('.0') ? v.substring(0, v.length - 2) : v}K';
  }
  return '$n';
}

class _StatsStrip extends StatelessWidget {
  const _StatsStrip();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final liked =
        context.select<FavoritesProvider, int>((p) => p.favorites.length);
    final playlists = context.select<PlaylistProvider, int>((p) => p.count);
    final artists = context
        .select<FollowedArtistsProvider, int>((p) => p.followed.length);
    final albums =
        context.select<FollowedAlbumsProvider, int>((p) => p.followed.length);

    Widget divider() => Container(
          width: 1,
          height: 30,
          color: AurumTheme.dividerOf(context),
        );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: Row(
        children: [
          _StatCell(
            value: _compact(liked),
            label: l10n.libraryLiked,
            onTap: () {
              AurumHaptics.selection();
              AurumDepthRoute.to(context, const LikedScreen());
            },
          ),
          divider(),
          _StatCell(value: _compact(playlists), label: l10n.libraryPlaylists),
          divider(),
          _StatCell(value: _compact(artists), label: l10n.libraryArtists),
          divider(),
          _StatCell(value: _compact(albums), label: l10n.libraryAlbums),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String value;
  final String label;
  final VoidCallback? onTap;
  const _StatCell({required this.value, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cell = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 24,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AurumTheme.textSecondaryOf(context),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );

    return Expanded(
      child: onTap == null
          ? cell
          : AurumPressable(
              onTap: onTap,
              haptic: false,
              scaleAmount: 0.94,
              child: cell,
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recently Played shelf — horizontal covers, tap to play.
// ─────────────────────────────────────────────────────────────────────────────

class _RecentlyPlayedShelf extends StatelessWidget {
  const _RecentlyPlayedShelf();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<RecentlyPlayedProvider>(
      builder: (context, rp, _) {
        final items = rp.history.take(12).toList();
        if (items.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  l10n.libraryRecentlyPlayed,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 196,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 14),
                  itemBuilder: (context, i) =>
                      _RecentTile(song: items[i], queue: items, index: i),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RecentTile extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _RecentTile(
      {required this.song, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    const size = 136.0;
    return AurumPressable(
      onTap: () {
        AurumHaptics.selection();
        context.read<PlayerProvider>().playSong(
              song,
              queue: queue,
              index: index,
              curatedQueue: true,
            );
      },
      scaleAmount: 0.95,
      haptic: false,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AurumArtwork(
              url: song.artworkUrl,
              size: size,
              borderRadius: 16,
            ),
            const SizedBox(height: 10),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Membership card — one compact card, features as chips.
// ─────────────────────────────────────────────────────────────────────────────

class _MembershipCard extends StatelessWidget {
  const _MembershipCard();

  static List<(IconData, String)> _perks(AppLocalizations l10n) => [
        (Icons.sync_rounded, l10n.prBenefitSyncTitle),
        (Icons.block_rounded, l10n.prBenefitAdFreeTitle),
        (Icons.high_quality_rounded, l10n.prBenefitQualityTitle),
        (Icons.download_done_rounded, l10n.prBenefitOfflineTitle),
        (Icons.recommend_rounded, l10n.prBenefitRecsTitle),
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accent = AurumTheme.accentOf(context);
    // Payment gate removed for now — every benefit is free with a Google
    // account, so the card always shows the unlocked state.
    const isPremium = true;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AurumTheme.accentDarkOf(context).withOpacity(0.34),
            accent.withOpacity(0.10),
          ],
        ),
        border: Border.all(color: accent.withOpacity(0.30), width: 0.9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AurumTheme.accentGradientOf(context),
                ),
                child: const Icon(Icons.workspace_premium_rounded,
                    color: Colors.black, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.prAurumPremiumPlain,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isPremium
                          ? l10n.prAllFeaturesUnlocked
                          : l10n.prUpgradeToUnlock,
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: accent.withOpacity(0.16),
                  border: Border.all(color: accent.withOpacity(0.45)),
                ),
                child: Text(
                  isPremium ? l10n.prActive : l10n.prFree,
                  style: TextStyle(
                    color: accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _perks(l10n)) _PerkChip(icon: p.$1, label: p.$2),
            ],
          ),
        ],
      ),
    );
  }
}

class _PerkChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _PerkChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 13, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AurumTheme.bgCardOf(context).withOpacity(0.7),
        border: Border.all(color: accent.withOpacity(0.18), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
