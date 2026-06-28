import 'package:aurum_music/widgets/aurum_loader.dart';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/premium_provider.dart';
import '../services/sync_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
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
        title: const Text('Profile',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: FadeTransition(
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero Header — Google photo blurred bg + name + email + gold badge
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileHero extends StatelessWidget {
  const _ProfileHero();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final avatarUrl = auth.avatarUrl;
    final name = auth.displayName ?? 'Aurum Listener';
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
                  fit: BoxFit.cover,
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
                          fit: BoxFit.cover,
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
                    child: const Text(
                      '✦ Aurum Premium',
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
          colors: [Color(0xFF1A1208), Color(0xFF2A1E00), Color(0xFF0D0D14)],
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

  static const _benefits = [
    (Icons.sync_rounded,           'Sync Library',       'Your music synced across all devices'),
    (Icons.all_inclusive_rounded,  'Lifetime Access',    'No subscriptions, yours forever'),
    (Icons.block_rounded,          'Ad-Free',            'Zero interruptions, pure music'),
    (Icons.high_quality_rounded,   'High Quality Audio', 'Best available stream quality'),
    (Icons.download_done_rounded,  'Offline Ready',      'Download and play anywhere'),
    (Icons.recommend_rounded,      'Smart Recommendations', 'Mood-based queue & discovery'),
  ];

  @override
  Widget build(BuildContext context) {
    final isPremium = context.watch<PremiumProvider>().isPremium;

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
                  Text('Aurum Premium',
                      style: TextStyle(
                        color: AurumTheme.gold,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      )),
                  Text(
                    isPremium ? 'All features unlocked' : 'Upgrade to unlock everything',
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
                  isPremium ? 'Active' : 'Free',
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
              children: _benefits.map((b) => _BenefitRow(
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
    final ok = await auth.signInWithGoogle();
    if (!mounted) return;
    if (ok) {
      // Refresh premium status after sign-in
      await context.read<PremiumProvider>().refresh();
      final isPremium = context.read<PremiumProvider>().isPremium;

      if (isPremium) {
        // Phase 3 — Cloud sync is premium-only
        setState(() => _syncing = true);
        try {
          await SyncService.instance.syncAll(
            playlists: context.read<PlaylistProvider>(),
            followedArtists: context.read<FollowedArtistsProvider>(),
            favorites: context.read<FavoritesProvider>(),
          );
        } finally {
          if (mounted) setState(() => _syncing = false);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Signed in — your library is synced'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Signed in! Upgrade to Premium to enable cloud sync.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ));
        }
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        title: Text('Sign out?',
            style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: Text(
          'Your playlists and library stay on this device. Sign back in anytime to sync again.',
          style: TextStyle(color: AurumTheme.textSecondaryOf(context)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true) await auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
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
                          auth.displayName ?? 'Signed in',
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
                            child: Text('Syncing your library…',
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
                        Text('Sync Your Library',
                            style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            )),
                        const SizedBox(height: 2),
                        Text('Sign in to access across devices',
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
                          label: const Text('Sign in'),
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
