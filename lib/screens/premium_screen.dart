// =============================================================================
// FILE: lib/screens/premium_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Aurum Plus paywall - Spotify-tier polish, Razorpay checkout.
//
//   ANIMATION SYSTEM:
//   - Entrance: staggered fade+slide cascade (hero -> plans -> features -> CTA)
//     using a single 900ms controller with offset Intervals (no jank, one
//     ticker driving everything).
//   - Hero: independent breathing glow (slow ease in/out) + diagonal shimmer
//     sweep across the crown, decoupled so they never look mechanical.
//   - Plan selection: AnimatedContainer + AnimatedDefaultTextStyle with
//     emphasized-decelerate curve, matches Material 3 "fast out, slow in"
//     feel used by big-name apps.
//   - CTA: continuous soft shimmer sweep + breathing glow shadow, scales
//     down slightly on press (tactile, not just color change).
//   - Success: scale+fade with elasticOut on the crown, then a delayed
//     staggered fade-up for text/button so it doesn't all pop at once.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/premium_provider.dart';
import '../services/payment_service.dart';
import '../theme/aurum_theme.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen>
    with TickerProviderStateMixin {
  // Entrance cascade
  late final AnimationController _entranceCtrl;
  late final Animation<double> _heroFade;
  late final Animation<Offset> _heroSlide;
  late final Animation<double> _plansFade;
  late final Animation<Offset> _plansSlide;
  late final Animation<double> _featuresFade;
  late final Animation<Offset> _featuresSlide;
  late final Animation<double> _ctaFade;
  late final Animation<Offset> _ctaSlide;

  // Hero glow breathing
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;

  // Hero shimmer sweep
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmer;

  // CTA press feedback
  late final AnimationController _pressCtrl;

  AurumPlan _selectedPlan = AurumPlan.yearly;
  bool _isProcessing = false;
  bool _justPaid = false;

  @override
  void initState() {
    super.initState();

    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    Animation<double> fadeFor(double start, double end) =>
        CurvedAnimation(
          parent: _entranceCtrl,
          curve: Interval(start, end, curve: Curves.easeOutCubic),
        );

    Animation<Offset> slideFor(double start, double end) =>
        Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceCtrl,
            curve: Interval(start, end, curve: Curves.easeOutCubic),
          ),
        );

    _heroFade = fadeFor(0.00, 0.45);
    _heroSlide = slideFor(0.00, 0.45);
    _plansFade = fadeFor(0.15, 0.60);
    _plansSlide = slideFor(0.15, 0.60);
    _featuresFade = fadeFor(0.30, 0.75);
    _featuresSlide = slideFor(0.30, 0.75);
    _ctaFade = fadeFor(0.50, 1.00);
    _ctaSlide = slideFor(0.50, 1.00);

    _entranceCtrl.forward();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOutSine);

    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
    _shimmer = CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOutSine);

    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      lowerBound: 0.0,
      upperBound: 0.04,
    );

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
    _pressCtrl.dispose();
    PaymentService.instance.dispose();
    super.dispose();
  }

  static const _features = [
    (Icons.high_quality_rounded, 'HD Audio', 'Crystal-clear 320kbps streaming'),
    (Icons.all_inclusive_rounded, 'Unlimited Skips', 'Skip as many songs as you want'),
    (Icons.block_rounded, 'Ad-Free', 'Zero interruptions, ever'),
    (Icons.auto_awesome_rounded, 'Smart Recommendations', 'Curated picks just for you'),
    (Icons.offline_pin_rounded, 'Offline Ready', 'Download and listen anywhere'),
    (Icons.cloud_sync_rounded, 'Cloud Sync', 'Your library across all devices'),
    (Icons.favorite_rounded, 'Like & Follow', 'Save songs and follow artists'),
    (Icons.queue_music_rounded, 'Create Playlists', 'Build your personal collections'),
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

  void _startCheckout() {
    HapticFeedback.mediumImpact();
    setState(() => _isProcessing = true);
    PaymentService.instance.startPayment(_selectedPlan);
  }

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<PremiumProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (premium.isPremium || _justPaid) {
      return _SuccessView(isDark: isDark);
    }

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF080808) : const Color(0xFFF7F2EA),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
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
                  FadeTransition(
                    opacity: _heroFade,
                    child: SlideTransition(position: _heroSlide, child: _buildHero(isDark)),
                  ),
                  const SizedBox(height: 34),
                  FadeTransition(
                    opacity: _plansFade,
                    child: SlideTransition(position: _plansSlide, child: _buildPlanSelector(isDark)),
                  ),
                  const SizedBox(height: 28),
                  FadeTransition(
                    opacity: _featuresFade,
                    child: SlideTransition(position: _featuresSlide, child: _buildFeatures(isDark)),
                  ),
                  const SizedBox(height: 36),
                  FadeTransition(
                    opacity: _ctaFade,
                    child: SlideTransition(position: _ctaSlide, child: _buildCTA(isDark)),
                  ),
                  const SizedBox(height: 16),
                  FadeTransition(
                    opacity: _ctaFade,
                    child: Text(
                      'Secure payments via Razorpay  •  Cancel anytime',
                      style: TextStyle(
                        color: isDark ? Colors.white30 : Colors.black38,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
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

  // -- Hero -------------------------------------------------------------------
  Widget _buildHero(bool isDark) {
    return Column(children: [
      AnimatedBuilder(
        animation: Listenable.merge([_glow, _shimmer]),
        builder: (_, __) {
          final glowStrength = 0.30 + (_glow.value * 0.25); // 0.30 -> 0.55
          final glowBlur = 26.0 + (_glow.value * 14.0); // 26 -> 40
          return Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AurumTheme.gold.withOpacity(0.32 + _glow.value * 0.12),
                  AurumTheme.gold.withOpacity(0.06),
                  Colors.transparent,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: AurumTheme.gold.withOpacity(glowStrength),
                  blurRadius: glowBlur,
                  spreadRadius: 4 + _glow.value * 4,
                ),
              ],
            ),
            child: Center(
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) {
                  final t = _shimmer.value; // 0 -> 1, eased
                  final sweep = (t * 2.6) - 0.8; // sweeps fully across and past
                  return LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: const [
                      AurumTheme.goldDark,
                      AurumTheme.goldLight,
                      AurumTheme.gold,
                    ],
                    stops: [
                      (sweep - 0.35).clamp(0.0, 1.0),
                      sweep.clamp(0.0, 1.0),
                      (sweep + 0.35).clamp(0.0, 1.0),
                    ],
                  ).createShader(bounds);
                },
                child: const Icon(Icons.workspace_premium_rounded,
                    color: Colors.white, size: 56),
              ),
            ),
          );
        },
      ),
      const SizedBox(height: 22),
      ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          colors: [AurumTheme.goldDark, AurumTheme.gold, AurumTheme.goldLight],
        ).createShader(bounds),
        child: const Text(
          'Aurum Plus',
          style: TextStyle(
            color: Colors.white,
            fontSize: 33,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.3,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'The ultimate music experience',
        style: TextStyle(
          color: isDark ? Colors.white54 : Colors.black45,
          fontSize: 15,
          letterSpacing: 0.1,
        ),
        textAlign: TextAlign.center,
      ),
    ]);
  }

  // -- Plan selector ------------------------------------------------------
  Widget _buildPlanSelector(bool isDark) {
    return Row(
      children: [
        Expanded(
          child: _PlanCard(
            plan: AurumPlan.monthly,
            isSelected: _selectedPlan == AurumPlan.monthly,
            isDark: isDark,
            onTap: () => _selectPlan(AurumPlan.monthly),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _PlanCard(
            plan: AurumPlan.yearly,
            isSelected: _selectedPlan == AurumPlan.yearly,
            isDark: isDark,
            badge: 'BEST VALUE',
            onTap: () => _selectPlan(AurumPlan.yearly),
          ),
        ),
      ],
    );
  }

  // -- Features --------------------------------------------------------------
  Widget _buildFeatures(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AurumTheme.gold.withOpacity(0.14), width: 0.8),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [Colors.white.withOpacity(0.05), Colors.white.withOpacity(0.02)]
              : [Colors.black.withOpacity(0.035), Colors.black.withOpacity(0.015)],
        ),
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
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AurumTheme.gold.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(f.$1, color: AurumTheme.gold, size: 19),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
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
                  ),
                ),
                const Icon(Icons.check_circle_rounded, color: AurumTheme.gold, size: 20),
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

  // -- CTA button ---------------------------------------------------------
  Widget _buildCTA(bool isDark) {
    final priceLabel = _selectedPlan == AurumPlan.monthly
        ? '${_selectedPlan.priceLabel}/month'
        : '${_selectedPlan.priceLabel}/year';

    if (_isProcessing) {
      return Container(
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AurumTheme.gold.withOpacity(0.18),
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(color: AurumTheme.gold, strokeWidth: 2.5),
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
              height: 58,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
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
                    color: AurumTheme.gold.withOpacity(0.40 + _glow.value * 0.2),
                    blurRadius: 22 + _glow.value * 8,
                    spreadRadius: 1,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  'Get Plus — $priceLabel',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// -- Plan card widget --------------------------------------------------------
class _PlanCard extends StatelessWidget {
  final AurumPlan plan;
  final bool isSelected;
  final bool isDark;
  final String? badge;
  final VoidCallback onTap;

  const _PlanCard({
    required this.plan,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: isSelected
              ? const LinearGradient(
                  colors: [AurumTheme.goldDark, AurumTheme.gold, AurumTheme.goldLight],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: isSelected
              ? null
              : (isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.03)),
          border: Border.all(
            color: isSelected ? Colors.transparent : AurumTheme.gold.withOpacity(0.18),
            width: 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 7),
                  ),
                ]
              : [],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(
                    color: isSelected
                        ? Colors.black87
                        : (isDark ? Colors.white70 : Colors.black87),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                  child: Text(plan.label),
                ),
                const SizedBox(height: 6),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(
                    color: isSelected ? Colors.black : (isDark ? Colors.white : Colors.black87),
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                  ),
                  child: Text(plan.priceLabel),
                ),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(
                    color: isSelected
                        ? Colors.black54
                        : (isDark ? Colors.white38 : Colors.black38),
                    fontSize: 11,
                  ),
                  child: Text(plan == AurumPlan.monthly ? 'per month' : 'per year'),
                ),
                const SizedBox(height: 10),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: Icon(
                    isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                    key: ValueKey(isSelected),
                    color: isSelected ? Colors.black : AurumTheme.gold.withOpacity(0.5),
                    size: 18,
                  ),
                ),
              ],
            ),
            if (badge != null)
              Positioned(
                top: -14,
                right: -6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AurumTheme.gold, width: 1),
                  ),
                  child: Text(
                    badge!,
                    style: const TextStyle(
                      color: AurumTheme.gold,
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

// -- Success view -------------------------------------------------------------
// Separate stateful widget so its own entrance animation runs fresh every
// time it mounts (e.g. right after payment success swaps the build tree).
class _SuccessView extends StatefulWidget {
  final bool isDark;
  const _SuccessView({required this.isDark});

  @override
  State<_SuccessView> createState() => _SuccessViewState();
}

class _SuccessViewState extends State<_SuccessView> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _crownScale;
  late final Animation<double> _crownFade;
  late final Animation<double> _textFade;
  late final Animation<Offset> _textSlide;
  late final Animation<double> _buttonFade;
  late final Animation<Offset> _buttonSlide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

    _crownScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.55, curve: Curves.elasticOut)),
    );
    _crownFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.3, curve: Curves.easeOut),
    );
    _textFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.35, 0.65, curve: Curves.easeOut),
    );
    _textSlide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.35, 0.65, curve: Curves.easeOutCubic)),
    );
    _buttonFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.6, 0.95, curve: Curves.easeOut),
    );
    _buttonSlide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.6, 0.95, curve: Curves.easeOutCubic)),
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
    final isDark = widget.isDark;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF080808) : const Color(0xFFF7F2EA),
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
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AurumTheme.goldGradient,
                      boxShadow: [
                        BoxShadow(
                          color: AurumTheme.gold.withOpacity(0.55),
                          blurRadius: 36,
                          spreadRadius: 6,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.workspace_premium_rounded,
                        color: Colors.black, size: 56),
                  ),
                ),
              ),
              const SizedBox(height: 30),
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
                            color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'All features are unlocked.\nEnjoy the full Aurum experience.',
                      style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.black45,
                        fontSize: 15,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 40),
              FadeTransition(
                opacity: _buttonFade,
                child: SlideTransition(
                  position: _buttonSlide,
                  child: SizedBox(
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
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text('Start Listening',
                            style: TextStyle(
                                color: Colors.black, fontSize: 15, fontWeight: FontWeight.w800)),
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
