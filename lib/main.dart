// ═══════════════════════════════════════════════════════════════════════
// NOTICE FOR ANY FUTURE EDITS TO THIS FILE (human or AI assistant):
//
// The "Full Player swipe-dismiss leaves a gray/black layer over the whole
// screen" bug (root cause: _FullPlayerRouteBackdrop in home_screen.dart
// not hiding itself before the pop's reverse transition finished) has
// been diagnosed AND FIXED. The fix lives in home_screen.dart
// (_FullPlayerRouteBackdropState listening to the route's own
// AnimationStatus and hiding on `reverse`/`dismissed`) and in
// mini_player.dart (offline/local artwork paths no longer falling back to
// a flat gray tint).
//
// While hunting that bug, this file temporarily carried debug-only code:
// a `_kDebugRouteStack` flag, an in-memory `aurumDebugRouteLog` list, an
// `_AurumDebugRouteObserver` NavigatorObserver logging every push/pop, and
// an always-on-top purple bug-report button (MaterialApp.builder) that
// opened a "Route log" AlertDialog. ALL of that has been removed — it was
// diagnostic scaffolding only, not part of the fix itself, and left in a
// release build it is dead weight at best and a source of new problems at
// worst (e.g. the bug-report button was hard-coded always-visible and sat
// above every route in the app).
//
// DO NOT reintroduce that debug observer/button/dialog to "help find" a
// related bug. If a similar full-screen overlay/backdrop issue resurfaces:
//   1. It is almost certainly in _FullPlayerRouteBackdrop
//      (home_screen.dart) or in one of the ColoredBox/BackdropFilter
//      layers inside full_player_screen.dart's _DragTransform — search
//      those first before adding new tooling.
//   2. If new diagnostics are genuinely needed, gate them behind
//      `kDebugMode` (from package:flutter/foundation.dart), never a
//      hand-rolled `const bool _kDebugXxx = true` that silently ships to
//      release builds, and remove them again before considering the bug
//      closed — don't leave them "temporarily" in a file that gets built
//      into a release APK.
// ═══════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/native_engine_bridge.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/audio_prefs.dart';
import 'services/battery_saver_controller.dart';
import 'services/sync_service.dart';
import 'providers/player_provider.dart';
import 'providers/library_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/locale_provider.dart';
import 'l10n/generated/app_localizations.dart';
import 'providers/download_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/followed_artists_provider.dart';
import 'providers/followed_albums_provider.dart';
import 'providers/saved_mixes_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/premium_provider.dart';
import 'theme/aurum_theme.dart';
import 'screens/main_shell.dart';
import 'screens/library_screen.dart';
import 'providers/source_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/recently_played_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/app_lock_screen.dart';
import 'utils/aurum_transitions.dart';
import 'utils/aurum_haptics.dart';

late NativeAudioEngine _audioEngine;

/// Global navigator key — lets the notification-tap callback (which fires
/// outside the widget tree) push the Downloads screen.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Global ScaffoldMessenger key — lets debug tooling (e.g. the keyboard
// flash watchdog) and any other code without a reliable local Scaffold
// ancestor (bottom sheets, dialogs) show a SnackBar reliably. Without
// this, ScaffoldMessenger.of(context) inside a sheet/dialog context can
// silently find no messenger and do nothing — which looks exactly like
// "the bug doesn't happen" even when it still does.
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Global RouteObserver — lets FullPlayerScreen pause ambient animations
/// whenever a route is pushed on top (lyrics, queue, options sheets).
final RouteObserver<ModalRoute<void>> aurumRouteObserver =
    RouteObserver<ModalRoute<void>>();

Future<void> main() async {
  runZonedGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();

  // THE fix for "background playback/notification unreliable on Android
  // 13+": AndroidManifest.xml already declares POST_NOTIFICATIONS, but
  // declaring a dangerous permission in the manifest does not grant it —
  // Android 13+ (API 33+) requires an explicit runtime request, exactly
  // like camera or location. Without this being granted, the system can
  // suppress AurumMediaSessionService's foreground notification entirely,
  // which in turn makes Android treat the service as a low-priority
  // "invisible" background process and kill it far more aggressively.
  // Requested here (pre-UI) because it's a lightweight, well-behaved
  // permission_handler call with no known crash history.
  //
  // Storage/audio and battery-optimization permissions are intentionally
  // NOT requested here anymore — they're requested from MainShell's first
  // frame instead (see main_shell.dart), fully inside the widget tree
  // after the splash animation and Flutter UI are actually up. Firing
  // multiple permission_handler system dialogs this early, before
  // Flutter's first frame has even been drawn, was the likely source of
  // the crash-on-launch some devices hit — permission_handler's platform
  // channel can be fragile if invoked before the Activity is fully
  // attached/resumed.
  // PERF FIX (the actual "app freezes for a second on open" cause): this
  // request used to be `await`-ed HERE, before runApp() — which meant
  // Flutter's very first frame couldn't even be painted until the user
  // dismissed the system permission dialog. On a device where that
  // dialog takes a moment to appear (or the user pauses before tapping),
  // the entire screen just sits blank/black, which reads exactly like
  // "the app is lagging/frozen on launch" even though nothing was
  // actually slow — Flutter was simply never given the chance to draw
  // anything yet.
  // The permission itself doesn't need to be granted before any UI can
  // show — it only affects whether the background playback notification
  // is visible later. Fired fire-and-forget after runApp() (see bottom
  // of this function) instead, so the splash/home UI paints immediately
  // and the system dialog appears as a normal overlay on top of a
  // already-visible, already-interactive app, the way permission
  // prompts work in virtually every other Android app.

  // Wake the Saavn free-tier backend the instant the app launches — by the
  // time the user reaches Home/Search it's had a head start to warm up.
  ApiService.wakeSaavn();

  // Hive init for local DB (favorites, playlists, recently played,
  // downloads) — GENUINELY MUST stay before runApp(). MultiProvider's
  // providers below fire their own `..init()` synchronously the instant
  // the widget tree builds inside runApp(), and 7 of them immediately
  // call `Hive.openBox(...)` — that throws if Hive hasn't been
  // initialized yet. This is a real dependency, not just caution.
  await Hive.initFlutter();

  // Supabase init — must happen before any AuthService/Supabase.instance
  // use. AuthProvider.init() (see MultiProvider below) runs synchronously
  // the moment runApp() builds the widget tree and immediately touches
  // Supabase.instance.client — deferring this past runApp() would crash
  // instead of just being slow. In practice this call is fast (local
  // client setup, no network round-trip of its own).
  try {
    await AuthService.init();
  } catch (_) {} // app still works fully offline/unauthenticated if this fails

  runApp(AurumApp(engine: _audioEngine = NativeAudioEngine()));

  // ── COLD-START HANG FIX — everything below used to run BEFORE runApp() ──
  // "app open karte hi bahut lag/hang hota hai" traced to this function
  // chaining 6+ sequential `await` calls ahead of runApp(): Hive init,
  // SharedPreferences.getInstance() (twice), AurumHaptics.init(),
  // SystemChrome.setPreferredOrientations(), AudioPrefs.load(). Flutter
  // cannot paint its first frame until main() reaches runApp() — so on
  // any device where even ONE of those calls is slow (cold disk cache,
  // a busy plugin channel, a slow first SharedPreferences read), the
  // screen sits completely blank for however long that chain takes,
  // which reads exactly like "the app is frozen/hanging on launch" even
  // though nothing had actually crashed or errored.
  //
  // None of the calls below affect what the very first frame needs to
  // look correct:
  //  • Image cache size (prefs.getDouble('max_image_cache')) only
  //    matters once images start decoding — Flutter's own default cache
  //    size is already a safe value for the brief window until this
  //    runs.
  //  • AurumHaptics.init() only affects whether the FIRST haptic tap
  //    feels right — inconsequential before the user has touched
  //    anything.
  //  • SystemChrome.setPreferredOrientations([portraitUp]) — the app is
  //    already portrait by default on the overwhelming majority of
  //    Android phones; locking it a few dozen ms later than before is
  //    not visually detectable.
  //  • AudioPrefs.load() overrides static defaults that AudioPrefs
  //    already ships with — every screen that reads them
  //    (backAnimationsNotifier, artworkShapeNotifier, etc.) does so via
  //    ValueNotifier/ChangeNotifier, so the UI simply starts on the
  //    built-in defaults for a beat and live-updates the instant this
  //    finishes, exactly like any other async-loaded preference in this
  //    app already does.
  //
  // Moving all of them here — after runApp() — means the very first
  // frame (splash screen) now paints as soon as the widget tree itself
  // is built, with zero dependency on disk/plugin-channel speed. Each
  // stays independently try/caught so one failing can never affect
  // another or crash the (already-running) app.
  try {
    final prefs = await SharedPreferences.getInstance();
    final maxImgMB = prefs.getDouble('max_image_cache') ?? 100.0;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        (maxImgMB * 1024 * 1024).toInt();
    // PERF FIX (2GB-RAM smoothness): Flutter's default imageCache.maximumSize
    // (item count, separate from the byte-size cap above) is 1000 — on a
    // long scroll session (Library with hundreds of tracks, or Search
    // results) that's up to 1000 decoded image entries kept alive with
    // their own bookkeeping/GC overhead, even while comfortably under the
    // byte-size limit above. Artwork here is small and heavily downscaled
    // already (see AurumArtwork._cacheSize — capped to size*2, or 220px for
    // blurred backgrounds), so 250 entries is still generous headroom for
    // smooth scrolling — several screens worth of visible + prefetched
    // tiles — while meaningfully cutting the worst-case memory/GC pressure
    // on weaker devices.
    PaintingBinding.instance.imageCache.maximumSize = 250;
  } catch (_) {}

  try {
    await AurumHaptics.init();
  } catch (_) {} // haptics simply fall back to 'light' behavior if this fails

  try {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  } catch (_) {}

  // Restore Player & Audio settings (shake-to-skip, swipe-to-change,
  // stop-on-swipe, pause-on-call, duck-on-notifications, etc.) from disk.
  // Every screen reads these through ValueNotifier/ChangeNotifier, so the
  // UI simply starts on AudioPrefs' built-in defaults for the brief
  // window until this resolves, then live-updates — same pattern as
  // every other async-loaded preference in the app.
  try {
    await AudioPrefs.load();
  } catch (_) {}

  // Battery Saver Mode: begin listening for live battery-percentage
  // updates immediately after prefs are loaded, so the enabled/threshold
  // values it reads are already correct from the very first native
  // battery event, not the hardcoded defaults. Fully synchronous/
  // fire-and-forget internally — never blocks startup (see
  // BatterySaverController.start()'s doc comment).
  try {
    BatterySaverController.instance.start();
  } catch (_) {}

  try {
    await Permission.notification.request();
  } catch (_) {}

  try {
    await NotificationService.instance.init();
    NotificationService.instance.onNotificationTapped = () {
      navigatorKey.currentState?.push(
        AurumPageRoute(builder: (_) => const DownloadsScreen()),
      );
    };
  } catch (_) {}
  }, (error, stack) {
    debugPrint('[Aurum] Uncaught error: $error\n$stack');
  });
}

class AurumApp extends StatelessWidget {
  final NativeAudioEngine engine;
  const AurumApp({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(
          create: (_) {
            final sp = SourceProvider();
            sp.init();
            return sp;
          },
        ),
        ChangeNotifierProvider(create: (_) => RecentlyPlayedProvider()..init()),
        ChangeNotifierProvider(create: (_) => DownloadProvider(engine)..init()),
        ChangeNotifierProxyProvider<DownloadProvider, FavoritesProvider>(
          create: (_) => FavoritesProvider()..init(),
          update: (_, dl, fav) {
            fav?.downloadProvider = dl;
            return fav ?? (FavoritesProvider()..init()..downloadProvider = dl);
          },
        ),
        ChangeNotifierProvider(create: (_) => PlaylistProvider()..init()),
        ChangeNotifierProvider(create: (_) => FollowedArtistsProvider()..init()),
        ChangeNotifierProvider(create: (_) => FollowedAlbumsProvider()..init()),
        ChangeNotifierProvider(create: (_) => SavedMixesProvider()..init()),
        ChangeNotifierProvider(
          create: (_) {
            final auth = AuthProvider();
            auth.init();
            // Keep AudioPrefs in sync so service-layer code (PlayerProvider)
            // can check isSignedIn without a BuildContext — mirrors the
            // isPremium wiring just below for the same reason.
            AudioPrefs.isSignedIn = auth.isSignedIn;
            auth.addListener(() => AudioPrefs.isSignedIn = auth.isSignedIn);
            return auth;
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final pp = PremiumProvider();
            // Spotify-style cross-device check: _refresh() now calls
            // Supabase's getUser() (real network round-trip, not the
            // locally cached session) so a payment made on another
            // device shows up here without the user having to sign out
            // and back in. If that check is stuck long enough to look
            // broken rather than just "loading", let them know it's a
            // connectivity problem, not premium being lost/denied.
            pp.onSlowNetwork = () {
              scaffoldMessengerKey.currentState?.showSnackBar(
                SnackBar(
                  content: const Text('Please check your internet connection'),
                  duration: const Duration(seconds: 3),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            };
            pp.init();
            // Keep AudioPrefs in sync so service-layer (ApiService) can
            // check isPremium without a BuildContext.
            pp.addListener(() => AudioPrefs.isPremium = pp.isPremium);
            // Same reasoning, for SyncService: incremental cloud pushes
            // (see providers/playlist_provider.dart etc.) fire from deep
            // inside provider mutation methods with no BuildContext
            // available, so SyncService needs its own way to ask "is this
            // user currently premium" right before deciding to push.
            SyncService.instance.isPremium = () => pp.isPremium;
            return pp;
          },
        ),
        ChangeNotifierProxyProvider2<RecentlyPlayedProvider, FavoritesProvider, PlayerProvider>(
          create: (context) {
            final p = PlayerProvider(engine);
            // See SourceProvider.isCurrentSongLocal: lets a connectivity
            // drop skip stopping playback when the current song is a
            // local file, since it doesn't need network to keep playing.
            context.read<SourceProvider>().isCurrentSongLocal =
                () => p.currentSong?.isLocal ?? false;
            // See SourceProvider.hasPlaybackBuffer: a connectivity drop
            // doesn't stop an online stream that still has buffered audio
            // left to play — matches Spotify, which keeps going until the
            // buffer is actually exhausted.
            context.read<SourceProvider>().hasPlaybackBuffer =
                () => p.hasPlaybackBuffer;
            // Spotify-style auto-resume: capture what was playing right
            // before a genuine connectivity drop stops it (see
            // onSourceChanged below), and pick it back up automatically —
            // same song, same position — the moment connectivity
            // genuinely returns, instead of leaving a dead stream sitting
            // there until the user notices and taps play again.
            context.read<SourceProvider>().onReconnected =
                () => p.resumeAfterReconnect();
            // Auto-switch is driven by real connectivity (see
            // SourceProvider.init()). When it flips while a song is
            // playing, the previous source's playback (online stream URL
            // or local file) is no longer valid for the new mode — stop
            // it immediately instead of leaving a dead/wrong song stuck
            // in the mini player. Captures what was playing first (see
            // markInterruptedByNetworkLoss) so onReconnected above can
            // pick it back up automatically once connectivity returns.
            //
            // FIX: engine.stop() is async and was called fire-and-forget
            // with no error handling. If the player has nothing loaded
            // (e.g. user toggles source before playing anything) or the
            // native ExoPlayer call throws, that became an unhandled
            // Future rejection that crashed the app the instant the
            // Online/Offline pill was tapped. Now any failure is caught
            // and swallowed — stopping playback is best-effort, it should
            // never be able to take down the UI.
            context.read<SourceProvider>().onSourceChanged = () {
              p.markInterruptedByNetworkLoss();
              engine.stop().catchError((e, st) {
                debugPrint('[Aurum] stop() on source change failed: $e');
              });
              // Only an online stream gets cut (see isCurrentSongLocal
              // above) — so if we're here, the user needs to know why
              // their music just stopped, rather than it looking like a
              // random freeze/crash.
              scaffoldMessengerKey.currentState?.showSnackBar(
                SnackBar(
                  content: const Text("You're offline — playback paused"),
                  duration: const Duration(seconds: 3),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            };
            // No-auto-skip resolve policy (see AurumAudioEngine.
            // resolveWithPatience): a slow-but-real connection never
            // skips or stops the song on its own — the native engine
            // just keeps quietly retrying in the background. This is
            // purely informational so the user understands why their
            // tap hasn't started playing yet, distinct from the offline
            // snackbar above (which fires only when the source has
            // genuinely switched to Offline). Edge-triggered in
            // PlayerProvider, so this shows once per stuck episode, not
            // once per retry.
            p.onResolveTakingLong = () {
              scaffoldMessengerKey.currentState?.showSnackBar(
                SnackBar(
                  content: const Text('Please check your internet connection'),
                  duration: const Duration(seconds: 3),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            };
            return p;
          },
          update: (_, recentlyPlayed, favorites, player) {
            final p = player ?? PlayerProvider(engine, recentlyPlayedProvider: recentlyPlayed);
            p.updateRecentlyPlayed(recentlyPlayed);
            p.updateFavorites(favorites);
            return p;
          },
        ),
      ],
      // DynamicColorBuilder harvests the system's wallpaper-derived
      // ColorScheme on Android 12+ (via the platform's dynamic color APIs)
      // and rebuilds whenever it changes — e.g. the user changes wallpaper
      // while Aurum is open, no app restart needed. On unsupported
      // platforms/OS versions both schemes come back null, which
      // ThemeProvider.isDynamicAvailable checks for before ever using them.
      child: DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          return Consumer2<ThemeProvider, LocaleProvider>(
            builder: (context, themeProvider, localeProvider, _) {
          // Push the latest schemes into ThemeProvider every build. This is
          // cheap (identical() short-circuits inside updateDynamicSchemes)
          // and is the only path through which "Dynamic Color" mode in
          // Settings > Appearance ever gets real colors to render with.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            themeProvider.updateDynamicSchemes(lightDynamic, darkDynamic);
          });

          // Single source of truth now lives on ThemeProvider (see
          // isDarkOf's FIX comment in theme_provider.dart) — pushFullPlayer
          // and FullPlayerScreen read the exact same method instead of each
          // re-deriving brightness independently via Theme.of(context).
          final isDark = themeProvider.isDarkOf(context);

          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            systemStatusBarContrastEnforced: false,
            // Transparent, not a solid fill — the nav bar is now a floating
            // glass capsule (see main_shell.dart's extendBody: true), with
            // real page content visible in the margins around/behind it.
            // A solid systemNavigationBarColor here painted a color strip
            // that didn't match that content, which flashed as a dark/black
            // edge during route push/pop slide transitions once the nav
            // bar stopped being an opaque full-width bar.
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarContrastEnforced: false,
          ));

          // Resolve font-aware ThemeData. Dynamic mode swaps in the
          // wallpaper-derived Material You scheme when one is actually
          // available (Android 12+); on any other platform/OS version it
          // silently behaves like the normal Dark theme instead of leaving
          // the user on a broken/blank theme.
          final baseLight = (themeProvider.isDynamic && lightDynamic != null)
              ? AurumTheme.dynamicTheme(lightDynamic)
              : AurumTheme.lightTheme;
          final baseDark = (themeProvider.isDynamic && darkDynamic != null)
              ? AurumTheme.dynamicTheme(darkDynamic)
              : (themeProvider.isAmoled
                  ? AurumTheme.amoledTheme
                  : AurumTheme.darkTheme);

          final lightTheme = baseLight.copyWith(
            textTheme: themeProvider.resolvedTextTheme(baseLight.textTheme),
          );
          final darkTheme = baseDark.copyWith(
            textTheme: themeProvider.resolvedTextTheme(baseDark.textTheme),
          );

          return MaterialApp(
            navigatorKey: navigatorKey,
            scaffoldMessengerKey: scaffoldMessengerKey,
            title: 'Aurum Music',
            debugShowCheckedModeBanner: false,
            themeMode: themeProvider.themeMode,
            theme: lightTheme,
            darkTheme: darkTheme,
            navigatorObservers: [aurumRouteObserver],
            locale: localeProvider.locale,
            supportedLocales: kSupportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            // If locale is null (user hasn't picked one — "follow system"),
            // Flutter tries to match the device's system locale against
            // supportedLocales. If the device is set to a language Aurum
            // doesn't ship translations for (e.g. German), this callback
            // falls back to English rather than Flutter's default behavior
            // of falling back to the first supportedLocales entry
            // regardless of fit — same practical result here since English
            // is first, but explicit so this doesn't silently break if the
            // list order ever changes.
            localeResolutionCallback: (deviceLocale, supported) {
              if (deviceLocale != null) {
                for (final l in supported) {
                  if (l.languageCode == deviceLocale.languageCode) return l;
                }
              }
              return const Locale('en');
            },
            // NOTE: _BlurShaderWarmup wraps here, OUTSIDE
            // _SplashOnEveryEntry's child. SplashScreen now mounts
            // MainShell immediately (as of the Echo-Nightly-matched
            // rewrite — see splash_screen.dart's own doc comment), so
            // the warmup would fire at the same moment either way; kept
            // at this outer level regardless so it's never nested inside
            // (and therefore never accidentally gated by) the splash
            // overlay's own build path.
            // Cross-fades dark/light/AMOLED + accent color changes instead
            // of the previous instant one-frame swap. MaterialApp already
            // builds the correct Theme internally (theme/darkTheme/
            // themeMode above); `child` here is that already-resolved
            // subtree. Re-reading Theme.of(context) and animating it with
            // AnimatedTheme smoothly interpolates every color that reads
            // through Theme.of(context) — which is virtually all of
            // aurum_theme.dart's *Of(context) helpers (scaffoldBackground
            // Color, colorScheme.surface/onSurface, dividerColor, etc,
            // used in 600+ places across the app) — with no changes needed
            // at any of those call sites.
            builder: (context, child) {
              return AnimatedTheme(
                data: Theme.of(context),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: _BlurShaderWarmup(
              child: AppLockScreen(
                child: _SplashOnEveryEntry(child: const MainShell()),
              ),
            ),
            ); // closes MaterialApp
            }, // closes Consumer2 builder
          ); // closes Consumer2
        }, // closes DynamicColorBuilder builder
      ), // closes DynamicColorBuilder
    ); // closes MultiProvider
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// _SplashOnEveryEntry
// ─────────────────────────────────────────────────────────────────────────────
//
// Shows the Aurum intro animation ONLY on a true cold start (first process
// launch). Background-resume (Home button → reopen, recents → reopen) skips
// straight back to whatever the user was doing — no repeated animation.
//
// How: a static bool `_played` is set to true the first time the splash
// completes. It lives on the class (not in State) so it survives hot-reload
// and background/foreground cycles for the entire Dart VM lifetime. On
// Android, AurumMediaSessionService (the native Kotlin foreground service)
// keeps the process alive in the background while music plays, so the Dart
// VM is not restarted on a normal resume — `_played` stays true and the
// splash is skipped. Only a genuine force-close + relaunch resets the
// process and clears `_played`, giving a fresh cold-start animation.
// ─────────────────────────────────────────────────────────────────────────────
// _BlurShaderWarmup
// ─────────────────────────────────────────────────────────────────────────────
//
// FIX (full player "3 second stuck" on open): the full player's background
// (_StaticBlurArtwork in full_player_screen.dart) uses ImageFilter.blur at a
// large sigma. The very FIRST time any ImageFilter.blur is painted in a
// process's lifetime, Skia has to compile/warm that blur shader on the GPU —
// a one-time cost that can run into the hundreds of ms to a few seconds on
// mid-range Android GPUs. Because that first blur used to happen the moment
// the user opened the full player, it read as the player being stuck/frozen.
//
// Fix: paint one throwaway 1x1 blurred box, fully offstage and invisible,
// the moment the app's widget tree first builds (right under the splash,
// so it's hidden either way). This forces Skia to compile the shader once,
// harmlessly, before the user ever taps a song — so the real first open is
// instant.
class _BlurShaderWarmup extends StatefulWidget {
  final Widget child;
  const _BlurShaderWarmup({required this.child});

  @override
  State<_BlurShaderWarmup> createState() => _BlurShaderWarmupState();
}

class _BlurShaderWarmupState extends State<_BlurShaderWarmup> {
  // Survives hot-reload / background-resume for the process lifetime, same
  // pattern as _SplashOnEveryEntry._played — only a real cold start should
  // pay this cost again.
  static bool _warmed = false;

  @override
  Widget build(BuildContext context) {
    if (_warmed) return widget.child;
    _warmed = true;
    return Stack(
      children: [
        widget.child,
        // Offstage: laid out and painted once (which is all we need to
        // force shader compilation) but never actually shown or hit-tested.
        Positioned(
          left: -100,
          top: -100,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: Stack(
                children: [
                  // Blur shader (nav bar, mini player, dialogs, mix/profile
                  // screens all use BackdropFilter.blur at various sigmas —
                  // one compile covers every sigma; Skia caches by filter
                  // *type*, not by parameter).
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: const SizedBox(width: 4, height: 4),
                  ),
                  // PERF FIX (extends the blur-only warmup above): the
                  // "very laggy for ~1 min, then smooth" symptom wasn't
                  // just the blur shader — Home's hero gradients, card
                  // drop-shadows, and rounded-rect image clips (artwork,
                  // hero cards) are each their own distinct Skia shader,
                  // and every one of them was still compiling for the
                  // first time exactly when the user hit it while
                  // scrolling Home right after launch. Warming the same
                  // small set of primitives Home actually paints with
                  // means those first real paints on Home are no longer
                  // "first ever" paints.
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: [
                          Colors.black.withValues(alpha: 0.4),
                          Colors.transparent,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 4,
                      height: 4,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SplashOnEveryEntry extends StatefulWidget {
  final Widget child;
  const _SplashOnEveryEntry({required this.child});

  @override
  State<_SplashOnEveryEntry> createState() => _SplashOnEveryEntryState();
}

class _SplashOnEveryEntryState extends State<_SplashOnEveryEntry> {
  // True after the splash has been mounted once per process lifetime —
  // set immediately (not deferred to a hand-off point) because
  // SplashScreen now mounts `child` in parallel with its own overlay
  // from frame 1 (see splash_screen.dart's doc comment for why), so
  // there's no longer a distinct "hand-off moment" to defer this to; a
  // second _SplashOnEveryEntry build within the same process (e.g. after
  // a full navigator reset) should just skip straight to `child` with no
  // overlay at all, matching Echo Nightly's own splash — which the OS
  // only ever shows once per process launch, never again on in-app
  // navigation resets.
  static bool _played = false;

  // BUG FIX ("splash animation nahi aa raha" — it played for a single
  // frame and was gone): this was a StatelessWidget flipping the static
  // `_played` flag directly inside build(). MaterialApp's `home` widget
  // sits underneath a Consumer2 (theme/locale providers) in this file,
  // and those providers finish their async init and notifyListeners()
  // within the very first few frames of a cold start — each one forces
  // this whole subtree, including _SplashOnEveryEntry, to rebuild. Since
  // `_played` was flipped to true on the FIRST of those builds, every
  // rebuild immediately after (often still within the same cold-start
  // burst, well before the intended 900ms animation had any chance to
  // run) already satisfied `if (_played) return child` and skipped
  // straight to the bare MainShell — so the splash overlay was mounted
  // and unmounted again inside a handful of frames, invisible in
  // practice. Deciding this once in initState (which never re-runs on
  // rebuild, only on a genuine new State object) instead of on every
  // build() call means the SplashScreen widget, once mounted, stays
  // mounted for its full 900ms regardless of how many times an ancestor
  // provider rebuilds this subtree in the meantime.
  late final bool _showSplash = !_played;

  @override
  void initState() {
    super.initState();
    _played = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSplash) return widget.child;
    return SplashScreen(
      key: const ValueKey('aurum_splash_once'),
      child: widget.child,
    );
  }
}
