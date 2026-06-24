// =============================================================================
// FILE: lib/screens/profile_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Premium Spotify-style profile screen.
//   ✅ Google Sign-In — tap avatar → Google popup → photo + name auto-filled
//   ✅ Signed-out state → shows "Sign in with Google" CTA
//   ✅ Signed-in state → Google photo, name, email, Sign Out button
//   ✅ Local override — user can still pick a local photo (takes priority)
//   ✅ Persists local avatar & name via SharedPreferences (UserProfile)
//   ✅ AuthProvider (ChangeNotifier) drives all reactive rebuilds
// =============================================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../theme/aurum_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// UserProfile — local persistence helper (unchanged API)
// ─────────────────────────────────────────────────────────────────────────────
class UserProfile {
  static const _kName       = 'profile_name';
  static const _kAvatarPath = 'profile_avatar_path';

  static Future<String?> getName() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kName);
  }

  static Future<void> setName(String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kName, name);
  }

  static Future<String?> getAvatarPath() async {
    final p = await SharedPreferences.getInstance();
    final path = p.getString(_kAvatarPath);
    if (path != null && await File(path).exists()) return path;
    return null;
  }

  static Future<void> setAvatarPath(String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAvatarPath, path);
  }

  static Future<void> clearAvatarPath() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kAvatarPath);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ProfileScreen
// ─────────────────────────────────────────────────────────────────────────────
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  // Local overrides
  String? _localAvatarPath;
  String  _localName = '';
  bool    _loading   = true;
  bool    _saving    = false;

  late final TextEditingController _nameCtrl;
  late final AnimationController   _fadeCtrl;
  late final Animation<double>     _fadeAnim;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final path = await UserProfile.getAvatarPath();
    final name = await UserProfile.getName();
    if (!mounted) return;
    setState(() {
      _localAvatarPath = path;
      _localName       = name ?? '';
      _nameCtrl.text   = _localName;
      _loading         = false;
    });
    _fadeCtrl.forward();
  }

  // ── Google Sign-In ────────────────────────────────────────────────────────
  Future<void> _handleGoogleSignIn() async {
    HapticFeedback.mediumImpact();
    final auth = context.read<AuthProvider>();
    if (auth.isSignedIn) return;
    await auth.signIn();

    // Auto-fill name from Google if user hasn't set a local one
    if (mounted && auth.isSignedIn && _localName.isEmpty) {
      final googleName = auth.displayName;
      _nameCtrl.text = googleName;
      await UserProfile.setName(googleName);
      setState(() => _localName = googleName);
    }
  }

  Future<void> _handleSignOut() async {
    HapticFeedback.lightImpact();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Sign out?',
            style: TextStyle(color: AurumTheme.textPrimaryOf(context),
                fontWeight: FontWeight.w700)),
        content: Text('You\'ll be signed out of your Google account.',
            style: TextStyle(color: AurumTheme.textMutedOf(context))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel',
                style: TextStyle(color: AurumTheme.textMutedOf(context))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out',
                style: TextStyle(color: Colors.redAccent,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<AuthProvider>().signOut();
    }
  }

  // ── Local avatar pick ─────────────────────────────────────────────────────
  Future<void> _pickImage() async {
    HapticFeedback.lightImpact();
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
    );
    if (picked == null) return;

    setState(() => _saving = true);
    try {
      final dir      = await getApplicationDocumentsDirectory();
      final ext      = picked.path.split('.').last;
      final destPath = '${dir.path}/profile_avatar.$ext';
      final destFile = File(destPath);
      if (await destFile.exists()) await destFile.delete();
      await File(picked.path).copy(destPath);
      await UserProfile.setAvatarPath(destPath);
      if (mounted) setState(() { _localAvatarPath = destPath; _saving = false; });
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveName() async {
    final value = _nameCtrl.text.trim();
    await UserProfile.setName(value);
    if (!mounted) return;
    setState(() => _localName = value);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Profile updated'),
      behavior: SnackBarBehavior.floating,
      backgroundColor: AurumTheme.gold,
      duration: const Duration(seconds: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    // Avatar priority: local file > Google photo > placeholder
    final Widget avatarChild = _buildAvatarChild(auth);

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded,
              color: AurumTheme.textSecondaryOf(context), size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Profile',
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AurumTheme.gold))
          : FadeTransition(
              opacity: _fadeAnim,
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 72,
                  bottom: 40,
                  left: 24,
                  right: 24,
                ),
                child: Column(
                  children: [
                    // ── Avatar ──────────────────────────────────────────────
                    _AvatarSection(
                      avatarChild: avatarChild,
                      saving: _saving,
                      isSignedIn: auth.isSignedIn,
                      onTap: auth.isSignedIn ? _pickImage : _handleGoogleSignIn,
                    ),
                    const SizedBox(height: 8),

                    // ── Google badge or "Sign in" CTA ────────────────────────
                    if (auth.isSignedIn) ...[
                      _GoogleBadge(email: auth.email ?? ''),
                      const SizedBox(height: 32),
                    ] else ...[
                      _GoogleSignInButton(onTap: _handleGoogleSignIn),
                      const SizedBox(height: 32),
                    ],

                    // ── Name field ───────────────────────────────────────────
                    _nameField(context),
                    const SizedBox(height: 16),
                    _saveButton(),

                    // ── Sign out ─────────────────────────────────────────────
                    if (auth.isSignedIn) ...[
                      const SizedBox(height: 24),
                      _signOutButton(),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  // ── Avatar child widget (priority: local > google > placeholder) ──────────
  Widget _buildAvatarChild(AuthProvider auth) {
    if (_localAvatarPath != null) {
      return Image.file(File(_localAvatarPath!), fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholderIcon());
    }
    if (auth.isSignedIn && auth.photoUrl != null) {
      return CachedNetworkImage(
        imageUrl: auth.photoUrl!,
        fit: BoxFit.cover,
        placeholder: (_, __) =>
            const CircularProgressIndicator(strokeWidth: 2, color: AurumTheme.gold),
        errorWidget: (_, __, ___) => _placeholderIcon(),
      );
    }
    return _placeholderIcon();
  }

  Widget _placeholderIcon() => Icon(Icons.person_rounded,
      size: 56, color: AurumTheme.textMutedOf(context));

  // ── Name field ────────────────────────────────────────────────────────────
  Widget _nameField(BuildContext context) {
    return TextField(
      controller: _nameCtrl,
      style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 16),
      decoration: InputDecoration(
        labelText: 'Display name',
        labelStyle: TextStyle(color: AurumTheme.textMutedOf(context)),
        filled: true,
        fillColor: AurumTheme.bgCardOf(context),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AurumTheme.gold),
        ),
      ),
      onSubmitted: (_) => _saveName(),
    );
  }

  Widget _saveButton() => SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      onPressed: _saveName,
      style: ElevatedButton.styleFrom(
        backgroundColor: AurumTheme.gold,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 0,
      ),
      child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
    ),
  );

  Widget _signOutButton() => SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: _handleSignOut,
      icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
      label: const Text('Sign out',
          style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        side: const BorderSide(color: Colors.redAccent, width: 0.8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// _AvatarSection
// ─────────────────────────────────────────────────────────────────────────────
class _AvatarSection extends StatelessWidget {
  final Widget avatarChild;
  final bool saving;
  final bool isSignedIn;
  final VoidCallback onTap;

  const _AvatarSection({
    required this.avatarChild,
    required this.saving,
    required this.isSignedIn,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: saving ? null : onTap,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          // Gold ring
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AurumTheme.goldGradient,
              boxShadow: [
                BoxShadow(
                  color: AurumTheme.gold.withOpacity(0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                )
              ],
            ),
            padding: const EdgeInsets.all(3),
            child: ClipOval(
              child: Container(
                color: AurumTheme.bgCardOf(context),
                child: avatarChild,
              ),
            ),
          ),
          // Badge
          if (saving)
            const Positioned.fill(
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            )
          else
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSignedIn ? AurumTheme.gold : Colors.white,
                border: Border.all(color: AurumTheme.bgOf(context), width: 2.5),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 6)
                ],
              ),
              child: isSignedIn
                  ? const Icon(Icons.camera_alt_rounded, size: 16, color: Colors.black)
                  : Padding(
                      padding: const EdgeInsets.all(6),
                      child: Image.network(
                        'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.login_rounded, size: 14, color: Colors.black87),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _GoogleBadge — shown when signed in
// ─────────────────────────────────────────────────────────────────────────────
class _GoogleBadge extends StatelessWidget {
  final String email;
  const _GoogleBadge({required this.email});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18, height: 18,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
            padding: const EdgeInsets.all(2),
            child: Image.network(
              'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
            ),
          ),
          const SizedBox(width: 8),
          Text(email,
              style: TextStyle(
                  color: AurumTheme.textMutedOf(context), fontSize: 12)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _GoogleSignInButton — shown when signed out
// ─────────────────────────────────────────────────────────────────────────────
class _GoogleSignInButton extends StatelessWidget {
  final VoidCallback onTap;
  const _GoogleSignInButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 12, offset: const Offset(0, 4))
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20, height: 20,
                child: Image.network(
                  'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.g_mobiledata_rounded, size: 20, color: Colors.blue),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Sign in with Google',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
