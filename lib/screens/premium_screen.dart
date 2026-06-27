// =============================================================================
// FILE: lib/screens/premium_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Premium paywall — Limited 1-Year Free offer via Google Sign-In.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/premium_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _shimmer = Tween<double>(begin: -1, end: 2).animate(
      CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  static const _features = [
    (Icons.high_quality_rounded,      '320kbps Streaming',    'Crystal-clear audio quality'),
    (Icons.all_inclusive_rounded,     'Unlimited Skips',      'Skip as many songs as you want'),
    (Icons.favorite_rounded,          'Like & Follow',        'Save songs and follow artists'),
    (Icons.queue_music_rounded,       'Create Playlists',     'Build your personal collections'),
    (Icons.cloud_sync_rounded,        'Cloud Sync',           'Your library across devices'),
    (Icons.palette_rounded,           'Exclusive Themes',     'Accent colors & player styles'),
  ];

  @override
  Widget build(BuildContext context) {
    final auth    = context.watch<AuthProvider>();
    final premium = context.watch<PremiumProvider>();
    final isDark  = Theme.of(context).brightness == Brightness.dark;

    // Already premium — show success state
    if (premium.isPremium) return _buildSuccess(context);

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F0E8),
      body: CustomScrollView(
        slivers: [
          // ── App bar ──────────────────────────────────────────────────────
          SliverAppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            pinned: false,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_rounded,
                  color: isDark ? Colors.white70 : Colors.black54),
              onPressed: () => Navigator.pop(context),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
              child: Column(
                children: [
                  // ── Hero crown ───────────────────────────────────────────
                  _buildHero(context, isDark),
                  const SizedBox(height: 32),

                  // ── Limited offer badge ──────────────────────────────────
                  _buildOfferBadge(context),
                  const SizedBox(height: 32),

                  // ── Feature list ─────────────────────────────────────────
                  _buildFeatures(context, isDark),
                  const SizedBox(height: 36),

                  // ── CTA ──────────────────────────────────────────────────
                  _buildCTA(context, auth, isDark),
                  const SizedBox(height: 16),

                  Text(
                    'No credit card required • Cancel anytime',
                    style: TextStyle(
                      color: isDark
                          ? Colors.white30
                          : Colors.black38,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Hero ─────────────────────────────────────────────────────────────────
  Widget _buildHero(BuildContext context, bool isDark) {
    return Column(children: [
      // Glowing crown icon
      AnimatedBuilder(
        animation: _shimmer,
        builder: (_, child) {
          return Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AurumTheme.gold.withOpacity(0.3),
                  AurumTheme.gold.withOpacity(0.05),
                  Colors.transparent,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: AurumTheme.gold.withOpacity(0.4),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: child,
          );
        },
        child: const Center(
          child: Icon(Icons.workspace_premium_rounded,
              color: AurumTheme.gold, size: 54),
        ),
      ),
      const SizedBox(height: 20),
      ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          colors: [AurumTheme.goldDark, AurumTheme.gold, AurumTheme.goldLight],
        ).createShader(bounds),
        child: const Text(
          'Aurum Premium',
          style: TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'The ultimate music experience',
        style: TextStyle(
          color: isDark ? Colors.white54 : Colors.black45,
          fontSize: 15,
        ),
        textAlign: TextAlign.center,
      ),
    ]);
  }

  // ── Limited offer badge ───────────────────────────────────────────────────
  Widget _buildOfferBadge(BuildContext context) {
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (_, child) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [
                AurumTheme.goldDark.withOpacity(0.9),
                AurumTheme.gold,
                AurumTheme.goldLight.withOpacity(0.9),
              ],
              stops: [0.0, 0.5, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: AurumTheme.gold.withOpacity(0.5),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: child,
        );
      },
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.local_offer_rounded, color: Colors.black, size: 18),
          const SizedBox(width: 8),
          const Text(
            '🎉  LIMITED OFFER',
            style: TextStyle(
              color: Colors.black,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        const Text(
          'Subscribe for FREE',
          style: TextStyle(
            color: Colors.black,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Get 1 Year of Premium Access — No Cost',
          style: TextStyle(
            color: Colors.black87,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  // ── Features ─────────────────────────────────────────────────────────────
  Widget _buildFeatures(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: AurumTheme.gold.withOpacity(0.15), width: 0.8),
        color: isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.black.withOpacity(0.03),
      ),
      child: Column(
        children: _features.asMap().entries.map((entry) {
          final i = entry.key;
          final f = entry.value;
          final isLast = i == _features.length - 1;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: AurumTheme.gold.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(f.$1, color: AurumTheme.gold, size: 19),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.$2,
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black87,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        )),
                    Text(f.$3,
                        style: TextStyle(
                          color: isDark ? Colors.white38 : Colors.black38,
                          fontSize: 12,
                        )),
                  ],
                )),
                const Icon(Icons.check_circle_rounded,
                    color: AurumTheme.gold, size: 20),
              ]),
            ),
            if (!isLast)
              Divider(
                height: 1,
                color: AurumTheme.gold.withOpacity(0.08),
                indent: 16,
                endIndent: 16,
              ),
          ]);
        }).toList(),
      ),
    );
  }

  // ── CTA button ───────────────────────────────────────────────────────────
  Widget _buildCTA(BuildContext context, AuthProvider auth, bool isDark) {
    if (auth.isSigningIn) {
      return Container(
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AurumTheme.gold.withOpacity(0.2),
        ),
        child: const Center(
          child: SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(
                color: AurumTheme.gold, strokeWidth: 2.5),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 58,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: () => _handleGoogleSignIn(context, auth),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Google G logo
              Container(
                width: 24, height: 24,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                child: const _GoogleLogo(),
              ),
              const SizedBox(width: 12),
              const Text(
                'Continue with Google',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleGoogleSignIn(
      BuildContext context, AuthProvider auth) async {
    final success = await auth.signInWithGoogle();
    if (!mounted) return;
    if (success) {
      await context.read<PremiumProvider>().refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('🎉 Premium unlocked! Enjoy 1 year free access.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ));
        Navigator.pop(context);
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sign-in failed. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<String> _getExpiryString() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('aurum_premium_granted_at');
    if (s == null) return '1 year from today';
    final granted = DateTime.tryParse(s);
    if (granted == null) return '1 year from today';
    final expiry = granted.add(const Duration(days: 365));
    return '\${expiry.day} \${_monthName(expiry.month)} \${expiry.year}';
  }

  String _monthName(int m) => const [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ][m];

  // ── Success state ─────────────────────────────────────────────────────────
  Widget _buildSuccess(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF0A0A0A)
          : const Color(0xFFF5F0E8),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 110, height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AurumTheme.goldGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold.withOpacity(0.5),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(Icons.workspace_premium_rounded,
                    color: Colors.black, size: 56),
              ),
              const SizedBox(height: 28),
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(
                  colors: [AurumTheme.goldDark, AurumTheme.gold],
                ).createShader(b),
                child: const Text(
                  'You\'re Premium! ✦',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'All features are unlocked.\nEnjoy your 1 year of free Premium access.',
                style: TextStyle(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white54
                      : Colors.black45,
                  fontSize: 15,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: AurumTheme.goldGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('Start Listening',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w800)),
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

// ── Google G logo (painted, no asset needed) ──────────────────────────────
class _GoogleLogo extends StatelessWidget {
  const _GoogleLogo();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GoogleLogoPainter(),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Simplified Google G using colored arcs
    final colors = [
      const Color(0xFF4285F4), // blue
      const Color(0xFF34A853), // green
      const Color(0xFFFBBC05), // yellow
      const Color(0xFFEA4335), // red
    ];

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.22
      ..strokeCap = StrokeCap.butt;

    const sweeps = [1.57, 1.57, 1.57, 1.57];
    const starts = [4.71, 0.0, 1.57, 3.14];

    for (int i = 0; i < 4; i++) {
      paint.color = colors[i];
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r * 0.72),
        starts[i],
        sweeps[i],
        false,
        paint,
      );
    }

    // White cutout for the G bar
    final barPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(center.dx, center.dy - r * 0.18, r * 0.85, r * 0.36),
      barPaint,
    );

    // Blue fill for G bar
    barPaint.color = const Color(0xFF4285F4);
    canvas.drawRect(
      Rect.fromLTWH(center.dx, center.dy - r * 0.14, r * 0.82, r * 0.28),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
