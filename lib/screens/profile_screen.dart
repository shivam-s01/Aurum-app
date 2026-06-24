import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/favorites_provider.dart';
import '../services/sync_service.dart';

/// Simple, persisted user profile (display name + local avatar image).
/// Not an auth/login system — just local personalization, Spotify-style.
class UserProfile {
  static const _kName = 'profile_name';
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
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _avatarPath;
  String _name = 'Your Name';
  bool _loading = true;
  bool _saving = false;
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final path = await UserProfile.getAvatarPath();
    final name = await UserProfile.getName();
    if (mounted) {
      setState(() {
        _avatarPath = path;
        _name = (name != null && name.trim().isNotEmpty) ? name : 'Your Name';
        _nameCtrl.text = _name == 'Your Name' ? '' : _name;
        _loading = false;
      });
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
    );
    if (picked == null) return;

    setState(() => _saving = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ext = picked.path.split('.').last;
      final destPath = '${dir.path}/profile_avatar.$ext';

      // Remove any previous avatar file first (different extension etc).
      final destFile = File(destPath);
      if (await destFile.exists()) await destFile.delete();
      await File(picked.path).copy(destPath);

      await UserProfile.setAvatarPath(destPath);
      if (mounted) setState(() { _avatarPath = destPath; _saving = false; });
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveName() async {
    final value = _nameCtrl.text.trim();
    await UserProfile.setName(value);
    if (mounted) {
      setState(() => _name = value.isEmpty ? 'Your Name' : value);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Profile updated'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ));
      FocusScope.of(context).unfocus();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded, color: AurumTheme.textSecondaryOf(context), size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Profile', style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AurumTheme.gold))
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                children: [
                  const _AccountCard(),
                  const SizedBox(height: 28),
                  GestureDetector(
                    onTap: _saving ? null : _pickImage,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: AurumTheme.goldGradient,
                          ),
                          padding: const EdgeInsets.all(3),
                          child: ClipOval(
                            child: _avatarPath != null
                                ? Image.file(File(_avatarPath!), fit: BoxFit.cover)
                                : Container(
                                    color: AurumTheme.bgCardOf(context),
                                    child: Icon(Icons.person_rounded, size: 56, color: AurumTheme.textMutedOf(context)),
                                  ),
                          ),
                        ),
                        if (_saving)
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
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AurumTheme.gold,
                              border: Border.all(color: AurumTheme.bgOf(context), width: 3),
                            ),
                            child: const Icon(Icons.camera_alt_rounded, size: 16, color: Colors.black),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Tap to change photo', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
                  const SizedBox(height: 32),
                  TextField(
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
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saveName,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AurumTheme.gold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      ),
                      child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// =============================================================================
// Account card — Google Sign-In entry point + signed-in state + sync trigger.
// Sits above the local-only name/avatar editor; fully independent of it.
// =============================================================================

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
        title: Text('Sign out?', style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: Text(
          'Your playlists and library stay on this device. Sign back in anytime to sync again.',
          style: TextStyle(color: AurumTheme.textSecondaryOf(context)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out', style: TextStyle(color: Colors.redAccent)),
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
          ),
          child: auth.isSignedIn
              ? Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: AurumTheme.gold.withOpacity(0.15),
                      backgroundImage: auth.avatarUrl != null
                          ? NetworkImage(auth.avatarUrl!)
                          : null,
                      child: auth.avatarUrl == null
                          ? const Icon(Icons.person_rounded, color: AurumTheme.gold)
                          : null,
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
                              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (_syncing)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Syncing your library…',
                                style: TextStyle(color: AurumTheme.gold, fontSize: 11),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _syncing
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AurumTheme.gold),
                          )
                        : IconButton(
                            icon: Icon(Icons.logout_rounded, color: AurumTheme.textMutedOf(context), size: 20),
                            onPressed: () => _handleSignOut(auth),
                          ),
                  ],
                )
              : Row(
                  children: [
                    Icon(Icons.account_circle_outlined, color: AurumTheme.textMutedOf(context), size: 28),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Sign in to sync your library across devices',
                        style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    auth.isSigningIn || _syncing
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AurumTheme.gold),
                          )
                        : OutlinedButton.icon(
                            onPressed: () => _handleSignIn(auth),
                            icon: const Icon(Icons.g_mobiledata_rounded, size: 20),
                            label: const Text('Sign in'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AurumTheme.gold,
                              side: const BorderSide(color: AurumTheme.gold),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            ),
                          ),
                  ],
                ),
        );
      },
    );
  }
}
