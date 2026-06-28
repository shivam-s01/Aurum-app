// =============================================================================
// FILE: lib/screens/premium_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Aurum Plus paywall — cinematic premium experience.
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/premium_provider.dart';
import '../services/payment_service.dart';
import '../theme/aurum_theme.dart';
import '../providers/auth_provider.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen>
    with TickerProviderStateMixin {
  // Entrance
  late final AnimationController _entranceCtrl;
  late final Animation<double> _heroFade, _plansFade, _featuresFade, _ctaFade;
  late final Animation<Offset> _heroSlide, _plansSlide, _featuresSlide, _ctaSlide;

  // Glow breathing
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;

  // Shimmer sweep
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmer;

  // Rotating particles
  late final AnimationController _particleCtrl;

  // CTA press
  late final AnimationController _pressCtrl;

  // Countdown timer for urgency (fake scarcity)
  late final AnimationController _countdownCtrl;

  AurumPlan _selectedPlan = AurumPlan.lifetime;
  bool _isProcessing = false;
  bool _justPaid = false;



  @override
  void initState() {
    super.initState();

    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    Animation<double> fadeFor(double s, double e) => CurvedAnimation(
          parent: _entranceCtrl,
          curve: Interval(s, e, curve: Curves.easeOutCubic),
        );
    Animation<Offset> slideFor(double s, double e) =>
        Tween<Offset>(begin: const Offset(0, 0.07), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceCtrl,
            curve: Interval(s, e, curve: Curves.easeOutCubic),
          ),
        );

    _heroFade = fadeFor(0.00, 0.45);
    _heroSlide = slideFor(0.00, 0.45);
    _plansFade = fadeFor(0.20, 0.65);
    _plansSlide = slideFor(0.20, 0.65);
    _featuresFade = fadeFor(0.38, 0.80);
    _featuresSlide = slideFor(0.38, 0.80);
    _ctaFade = fadeFor(0.55, 1.00);
    _ctaSlide = slideFor(0.55, 1.00);

    _entranceCtrl.forward();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOutSine);

    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
    _shimmer =
        CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOutSine);

    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8000),
    )..repeat();

    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      lowerBound: 0.0,
      upperBound: 0.04,
    );

    _countdownCtrl = AnimationController(
      vsync: this,
      duration: const Duration(hours: 24),
    )..forward();

    PaymentService.instance.init(
      onSuccess: _handlePaymentSuccess,
      onError: _handlePaymentError,
      onCancelled: _handlePaymentCancelled,
    );
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _glowCtrl.dispose();
    _shimmerCtrl.dispose();
    _particleCtrl.dispose();
    _pressCtrl.dispose();
    _countdownCtrl.dispose();
    PaymentService.instance.dispose();
    super.dispose();
  }

  static const _features = [
    (Icons.high_quality_rounded, 'HD Audio • 320kbps',
        'Crystal-clear lossless quality'),
    (Icons.all_inclusive_rounded, 'Unlimited Skips',
        'Skip as many songs as you want'),
    (Icons.block_rounded, 'Zero Ads', 'Completely ad-free experience'),
    (Icons.auto_awesome_rounded, 'AI Recommendations',
        'Songs curated just for you'),
    (Icons.offline_pin_rounded, 'Offline Downloads',
        'Listen without internet'),
    (Icons.cloud_sync_rounded, 'Cloud Sync',
        'Your library on every device'),
    (Icons.favorite_rounded, 'Like & Follow Artists',
        'Build your personal collection'),
    (Icons.queue_music_rounded, 'Unlimited Playlists',
        'Create and share playlists'),
    (Icons.palette_rounded, 'Exclusive Themes',
        'Premium colors and player styles'),
  ];

  void _handlePaymentSuccess(AurumPlan plan, String paymentId) {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    context.read<PremiumProvider>().markPremiumGranted(plan.id);
    setState(() {
      _isProcessing = false;
      _justPaid = true;
    });
  }

  void _handlePaymentError(String message) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() => _isProcessing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2A1414),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  void _handlePaymentCancelled() {
    if (!mounted) return;
    setState(() => _isProcessing = false);
  }

  void _selectPlan(AurumPlan plan) {
    if (plan == _selectedPlan) return;
    HapticFeedback.selectionClick();
    setState(() => _selectedPlan = plan);
  }

  Future<void> _startCheckout() async {
    HapticFeedback.mediumImpact();
    final auth = context.read<AuthProvider>();

    if (!auth.isSignedIn) {
      setState(() => _isProcessing = true);
      final success = await auth.signInWithGoogle();
      if (!mounted) return;
      if (!success) {
        setState(() => _isProcessing = false);
        return;
      }
    } else {
      setState(() => _isProcessing = true);
    }

    final auth2 = context.read<AuthProvider>();
    PaymentService.instance.startPayment(
      _selectedPlan,
      userEmail: auth2.email,
      userName: auth2.displayName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<PremiumProvider>();

    if (premium.isPremium || _justPaid) {
      return const _SuccessView();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF060608),
      body: Stack(
        children: [
          // Animated particle background
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _particleCtrl,
              builder: (_, __) => CustomPaint(
                size: Size.infinite,
                painter: _ParticlePainter(_particleCtrl.value),
              ),
            ),
          ),
          // Top gold glow blob
          AnimatedBuilder(
            animation: _glow,
            builder: (_, __) => Positioned(
              top: -80,
              left: 0,
              right: 0,
              child: Container(
                height: 300,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      AurumTheme.gold.withOpacity(0.18 + _glow.value * 0.08),
                      Colors.transparent,
                    ],
                    radius: 0.8,
                  ),
                ),
              ),
            ),
          ),
          // Main content
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                pinned: false,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: Colors.white54),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  child: Column(
                    children: [
                      FadeTransition(
                        opacity: _heroFade,
                        child: SlideTransition(
                          position: _heroSlide,
                          child: _buildHero(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Social proof bar
                      FadeTransition(
                        opacity: _heroFade,
                        child: _buildSocialProof(),
                      ),
                      const SizedBox(height: 28),
                      FadeTransition(
                        opacity: _plansFade,
                        child: SlideTransition(
                          position: _plansSlide,
                          child: _buildPlanSelector(),
                        ),
                      ),
                      const SizedBox(height: 24),
                      FadeTransition(
                        opacity: _featuresFade,
                        child: SlideTransition(
                          position: _featuresSlide,
                          child: _buildFeatures(),
                        ),
                      ),
                      const SizedBox(height: 32),
                      FadeTransition(
                        opacity: _ctaFade,
                        child: SlideTransition(
                          position: _ctaSlide,
                          child: _buildCTA(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FadeTransition(
                        opacity: _ctaFade,
                        child: _buildFooter(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHero() {
    return Column(children: [
      AnimatedBuilder(
        animation: Listenable.merge([_glow, _shimmer]),
        builder: (_, __) {
          return Stack(
            alignment: Alignment.center,
            children: [
              // Outer glow ring
              Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AurumTheme.gold.withOpacity(0.25 + _glow.value * 0.15),
                      AurumTheme.gold.withOpacity(0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              // Inner circle
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AurumTheme.goldDark,
                      AurumTheme.gold,
                      AurumTheme.goldLight,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold
                          .withOpacity(0.5 + _glow.value * 0.25),
                      blurRadius: 30 + _glow.value * 15,
                      spreadRadius: 2 + _glow.value * 4,
                    ),
                  ],
                ),
                child: ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) {
                    final t = _shimmer.value;
                    final sweep = (t * 2.6) - 0.8;
                    return LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: const [
                        Colors.black87,
                        Colors.white,
                        Colors.black87,
                      ],
                      stops: [
                        (sweep - 0.35).clamp(0.0, 1.0),
                        sweep.clamp(0.0, 1.0),
                        (sweep + 0.35).clamp(0.0, 1.0),
                      ],
                    ).createShader(bounds);
                  },
                  child: const Icon(Icons.workspace_premium_rounded,
                      color: Colors.white, size: 48),
                ),
              ),
            ],
          );
        },
      ),
      const SizedBox(height: 24),
      ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          colors: [AurumTheme.goldDark, AurumTheme.goldLight, AurumTheme.gold],
        ).createShader(bounds),
        child: const Text(
          'Aurum Plus',
          style: TextStyle(
            color: Colors.white,
            fontSize: 36,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Music, the way it was meant to be heard.',
        style: TextStyle(
          color: Colors.white.withOpacity(0.55),
          fontSize: 15,
          letterSpacing: 0.1,
        ),
        textAlign: TextAlign.center,
      ),
    ]);
  }

  Widget _buildSocialProof() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _TrustBadge(icon: Icons.star_rounded, label: '4.9★ Rating'),
        const SizedBox(width: 10),
        _TrustBadge(icon: Icons.lock_rounded, label: 'Secure'),
        const SizedBox(width: 10),
        _TrustBadge(icon: Icons.replay_rounded, label: '7-day refund'),
      ],
    );
  }


  Widget _buildPlanSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12, left: 2),
          child: Text(
            'Choose your plan',
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _PlanCard(
                plan: AurumPlan.monthly,
                isSelected: _selectedPlan == AurumPlan.monthly,
                badge: 'TRY IT',
                onTap: () => _selectPlan(AurumPlan.monthly),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PlanCard(
                plan: AurumPlan.yearly,
                isSelected: _selectedPlan == AurumPlan.yearly,
                badge: 'SAVE 58%',
                onTap: () => _selectPlan(AurumPlan.yearly),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _PlanCard(
          plan: AurumPlan.lifetime,
          isSelected: _selectedPlan == AurumPlan.lifetime,
          badge: 'BEST DEAL',
          isFullWidth: true,
          onTap: () => _selectPlan(AurumPlan.lifetime),
        ),
      ],
    );
  }

  Widget _buildFeatures() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14, left: 2),
          child: Text(
            'Everything included',
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white.withOpacity(0.04),
            border: Border.all(
              color: AurumTheme.gold.withOpacity(0.15),
              width: 0.8,
            ),
          ),
          child: Column(
            children: _features.asMap().entries.map((entry) {
              final i = entry.key;
              final f = entry.value;
              final isLast = i == _features.length - 1;
              return Column(children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                  child: Row(children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AurumTheme.gold.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(f.$1, color: AurumTheme.gold, size: 18),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.$2,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              )),
                          Text(f.$3,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 11.5,
                              )),
                        ],
                      ),
                    ),
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AurumTheme.gold.withOpacity(0.15),
                      ),
                      child: const Icon(Icons.check_rounded,
                          color: AurumTheme.gold, size: 13),
                    ),
                  ]),
                ),
                if (!isLast)
                  Divider(
                    height: 1,
                    color: Colors.white.withOpacity(0.05),
                    indent: 16,
                    endIndent: 16,
                  ),
              ]);
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildCTA() {
    final priceLabel = switch (_selectedPlan) {
      AurumPlan.monthly  => '${_selectedPlan.priceLabel}/month',
      AurumPlan.yearly   => '${_selectedPlan.priceLabel}/year',
      AurumPlan.lifetime => '${_selectedPlan.priceLabel} one-time',
    };
    final isSignedIn = context.watch<AuthProvider>().isSignedIn;

    if (_isProcessing) {
      return Container(
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AurumTheme.gold.withOpacity(0.15),
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
                color: AurumTheme.gold, strokeWidth: 2.5),
          ),
        ),
      );
    }

    return GestureDetector(
      onTapDown: (_) => _pressCtrl.forward(),
      onTapUp: (_) => _pressCtrl.reverse(),
      onTapCancel: () => _pressCtrl.reverse(),
      onTap: _startCheckout,
      child: AnimatedBuilder(
        animation: Listenable.merge([_shimmer, _glow, _pressCtrl]),
        builder: (_, __) {
          final t = _shimmer.value;
          final sweep = (t * 2.6) - 0.8;
          final scale = 1.0 - _pressCtrl.value;
          return Transform.scale(
            scale: scale,
            child: Container(
              height: 62,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: const [
                    AurumTheme.goldDark,
                    AurumTheme.goldLight,
                    AurumTheme.gold,
                  ],
                  stops: [
                    (sweep - 0.4).clamp(0.0, 1.0),
                    sweep.clamp(0.0, 1.0),
                    (sweep + 0.4).clamp(0.0, 1.0),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color:
                        AurumTheme.gold.withOpacity(0.45 + _glow.value * 0.2),
                    blurRadius: 24 + _glow.value * 10,
                    spreadRadius: 1,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.workspace_premium_rounded,
                        color: Colors.black, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      isSignedIn
                          ? 'Get Plus — $priceLabel'
                          : 'Sign in & Get Plus',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    return Column(
      children: [
        Text(
          '🔒  Secure payments via Razorpay  •  Cancel anytime',
          style: TextStyle(
            color: Colors.white.withOpacity(0.3),
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        // Money back
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_rounded,
                color: AurumTheme.gold.withOpacity(0.7), size: 14),
            const SizedBox(width: 5),
            Text(
              '7-day money back guarantee',
              style: TextStyle(
                color: AurumTheme.gold.withOpacity(0.7),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Particle painter ────────────────────────────────────────────────────────

// ── Trust badge ──────────────────────────────────────────────────────────────

class _TrustBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: AurumTheme.gold.withOpacity(0.2), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AurumTheme.gold, size: 13),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.65),
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Particle painter ─────────────────────────────────────────────────────────

class _ParticlePainter extends CustomPainter {
  final double t;
  static final _rng = math.Random(42);
  static final _particles = List.generate(18, (i) => [
    _rng.nextDouble(), // x factor
    _rng.nextDouble(), // y factor
    _rng.nextDouble(), // speed factor
    _rng.nextDouble(), // size factor
    _rng.nextDouble(), // opacity factor
  ]);

  _ParticlePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in _particles) {
      final x = p[0] * size.width;
      final y = ((p[1] + t * p[2] * 0.3) % 1.0) * size.height;
      final radius = 1.0 + p[3] * 2.5;
      final opacity = (0.08 + p[4] * 0.18) *
          (0.5 + 0.5 * math.sin(t * math.pi * 2 * (0.5 + p[2])));

      canvas.drawCircle(
        Offset(x, y),
        radius,
        Paint()
          ..color = AurumTheme.gold.withOpacity(opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.t != t;
}

// ── Plan card ────────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final AurumPlan plan;
  final bool isSelected;
  final String? badge;
  final bool isFullWidth;
  final VoidCallback onTap;

  const _PlanCard({
    required this.plan,
    required this.isSelected,
    required this.onTap,
    this.badge,
    this.isFullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final subLabel = switch (plan) {
      AurumPlan.monthly  => 'per month',
      AurumPlan.yearly   => 'per year',
      AurumPlan.lifetime => 'pay once, own forever',
    };

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        width: isFullWidth ? double.infinity : null,
        padding: EdgeInsets.symmetric(
          vertical: isFullWidth ? 14 : 18,
          horizontal: 14,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: isSelected
              ? const LinearGradient(
                  colors: [
                    AurumTheme.goldDark,
                    AurumTheme.gold,
                    AurumTheme.goldLight,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: isSelected ? null : Colors.white.withOpacity(0.05),
          border: Border.all(
            color: isSelected
                ? Colors.transparent
                : Colors.white.withOpacity(0.1),
            width: 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.45),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ]
              : [],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            isFullWidth
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 220),
                            style: TextStyle(
                              color:
                                  isSelected ? Colors.black87 : Colors.white60,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                            child: Text(plan.label.toUpperCase()),
                          ),
                          const SizedBox(height: 2),
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 220),
                            style: TextStyle(
                              color:
                                  isSelected ? Colors.black54 : Colors.white38,
                              fontSize: 11,
                            ),
                            child: Text(subLabel),
                          ),
                        ],
                      ),
                      Row(children: [
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 220),
                          style: TextStyle(
                            color: isSelected ? Colors.black : Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                          ),
                          child: Text(plan.priceLabel),
                        ),
                        const SizedBox(width: 12),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Icon(
                            isSelected
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            key: ValueKey(isSelected),
                            color: isSelected
                                ? Colors.black
                                : Colors.white.withOpacity(0.3),
                            size: 20,
                          ),
                        ),
                      ]),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 220),
                        style: TextStyle(
                          color: isSelected ? Colors.black87 : Colors.white60,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                        child: Text(plan.label.toUpperCase()),
                      ),
                      const SizedBox(height: 6),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 220),
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                        ),
                        child: Text(plan.priceLabel),
                      ),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 220),
                        style: TextStyle(
                          color: isSelected ? Colors.black54 : Colors.white38,
                          fontSize: 11,
                        ),
                        child: Text(subLabel),
                      ),
                      const SizedBox(height: 10),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Icon(
                          isSelected
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          key: ValueKey(isSelected),
                          color: isSelected
                              ? Colors.black
                              : Colors.white.withOpacity(0.3),
                          size: 18,
                        ),
                      ),
                    ],
                  ),
            if (badge != null)
              Positioned(
                top: -12,
                right: -4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: AurumTheme.gold, width: 0.8),
                  ),
                  child: Text(
                    badge!,
                    style: const TextStyle(
                      color: AurumTheme.goldLight,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Success view ─────────────────────────────────────────────────────────────

class _SuccessView extends StatefulWidget {
  const _SuccessView();

  @override
  State<_SuccessView> createState() => _SuccessViewState();
}

class _SuccessViewState extends State<_SuccessView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _crownScale, _crownFade, _textFade, _buttonFade;
  late final Animation<Offset> _textSlide, _buttonSlide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100));

    _crownScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
          parent: _ctrl,
          curve: const Interval(0.0, 0.55, curve: Curves.elasticOut)),
    );
    _crownFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.3, curve: Curves.easeOut),
    );
    _textFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.35, 0.65, curve: Curves.easeOut),
    );
    _textSlide =
        Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
      CurvedAnimation(
          parent: _ctrl,
          curve: const Interval(0.35, 0.65, curve: Curves.easeOutCubic)),
    );
    _buttonFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.6, 0.95, curve: Curves.easeOut),
    );
    _buttonSlide =
        Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
      CurvedAnimation(
          parent: _ctrl,
          curve: const Interval(0.6, 0.95, curve: Curves.easeOutCubic)),
    );

    _ctrl.forward();
    HapticFeedback.mediumImpact();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060608),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeTransition(
                opacity: _crownFade,
                child: ScaleTransition(
                  scale: _crownScale,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AurumTheme.goldGradient,
                      boxShadow: [
                        BoxShadow(
                          color: AurumTheme.gold.withOpacity(0.6),
                          blurRadius: 40,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.workspace_premium_rounded,
                        color: Colors.black, size: 58),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              FadeTransition(
                opacity: _textFade,
                child: SlideTransition(
                  position: _textSlide,
                  child: Column(children: [
                    ShaderMask(
                      shaderCallback: (b) => const LinearGradient(
                        colors: [AurumTheme.goldDark, AurumTheme.gold],
                      ).createShader(b),
                      child: const Text(
                        "You're Plus now ✦",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'All features are unlocked.\nEnjoy the full Aurum experience.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 15,
                        height: 1.55,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 44),
              FadeTransition(
                opacity: _buttonFade,
                child: SlideTransition(
                  position: _buttonSlide,
                  child: SizedBox(
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: AurumTheme.goldGradient,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AurumTheme.gold.withOpacity(0.4),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 17),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Start Listening',
                            style: TextStyle(
                                color: Colors.black,
                                fontSize: 16,
                                fontWeight: FontWeight.w900)),
                      ),
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
