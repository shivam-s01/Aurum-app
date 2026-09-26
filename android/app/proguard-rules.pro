# =====================================================================
# AGGRESSIVE OBFUSCATION MODE
# =====================================================================
# Goal: make static analysis / decompiled output of com.aurum.music.**
# as unreadable as R8 allows, while keeping ONLY the entry points that
# Android OS / Flutter / reflection call by exact name (breaking any of
# these crashes the app at runtime with no compile-time warning, since
# none of these call sites are visible to R8's static analysis).
#
# This replaces the old blanket `-keep class com.aurum.music.** { *; }`
# rule, which exempted 100% of this app's own code from obfuscation —
# every class/method name, and the whole call graph, was fully readable
# in any decompiled APK regardless of minifyEnabled/shrinkResources.
# =====================================================================

-allowaccessmodification
-repackageclasses ''
-flattenpackagehierarchy ''
-overloadaggressively
-optimizationpasses 5
-mergeinterfacesaggressively

-optimizations !class/merging/horizontal,!code/allocation/variable,!field/*,!class/unboxing/enum

-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute ""

# ---- Flutter (required, standard) ----
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# ---- This app's own native classes ----
# ONLY entry points instantiated/looked-up by exact class name from
# outside this codebase (Android OS via AndroidManifest.xml, or
# Flutter's plugin registrar) are kept BY NAME. Their internal method
# bodies, private members, and every other class in the package are
# still fully obfuscated/renamed/repackaged — only the class name
# itself (and its public constructor/lifecycle overrides, which are
# called by signature, not by name, via `<init>` and `extends`) survive.
-keep public class com.aurum.music.MainActivity { public <init>(); }
-keep public class com.aurum.music.AurumMediaSessionService { public <init>(); }
-keep public class com.aurum.music.AurumWidgetProvider { public <init>(); }
-keep public class com.aurum.music.AurumWidgetProviderFull { public <init>(); }
-keep public class com.aurum.music.AutoSleepGuardReceiver { public <init>(); }
-keep public class com.aurum.music.AutoSleepGuardActionReceiver { public <init>(); }
-keep public class com.aurum.music.AurumCastOptionsProvider { public <init>(); }

# Base classes these extend (Service/BroadcastReceiver/AppWidgetProvider/
# Activity) call overridden lifecycle methods by signature — keep the
# override names on the entry-point classes above only, not the whole
# package.
-keepclassmembers class com.aurum.music.MainActivity extends io.flutter.embedding.android.FlutterActivity { *; }
-keepclassmembers class com.aurum.music.AurumMediaSessionService extends androidx.media3.session.MediaSessionService { *; }
-keepclassmembers class com.aurum.music.AurumWidgetProvider extends android.appwidget.AppWidgetProvider { *; }
-keepclassmembers class com.aurum.music.AurumWidgetProviderFull extends android.appwidget.AppWidgetProvider { *; }
-keepclassmembers class * extends android.content.BroadcastReceiver { *; }
-keepclassmembers class * implements com.google.android.gms.cast.framework.OptionsProvider { *; }

# Everything else in com.aurum.music.** (AurumAudioEngine, YoutubeInnertube,
# HybridStreamResolver, AurumCastManager, channel handlers, etc) gets NO
# blanket keep — class names, method names, and field names are all fair
# game for obfuscation/repackaging.

# ---- Native (JNI) bridge ----
# aurum_guard.cpp binds to this exact class/method name
# (Java_com_aurum_music_AurumIntegrityGuard_nativeCheckSuspicious) — if
# R8 renames either the class or the method, JNI lookup fails at runtime
# with UnsatisfiedLinkError, silently (no compile-time warning, since R8
# can't see into the .so). This keeps ONLY the native method signature,
# not the rest of the class, which stays fully obfuscated as before.
-keepclasseswithmembernames class com.aurum.music.AurumIntegrityGuard {
    native <methods>;
}

# ---- Media3 / ExoPlayer ----
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# ---- NewPipeExtractor + NewValve (YouTube resolution) ----
# Uses reflection-heavy JSON parsing (Jsoup, its own JSON extractor) internally;
# stripping unused-looking methods here breaks parsing of live YouTube responses.
# NOTE: this keeps the THIRD-PARTY library's own classes intact (required
# for it to function) — it does not re-expose this app's usage of it.
-keep class org.schabi.newpipe.** { *; }
-keep class com.github.shalva97.** { *; }
-dontwarn org.schabi.newpipe.**
-keep class org.jsoup.** { *; }
-dontwarn org.jsoup.**

# ---- OkHttp / Okio (networking) ----
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ---- Kotlin coroutines ----
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-dontwarn kotlinx.coroutines.**

# ---- Gson / JSON models (if reflection-based (de)serialization is used anywhere) ----
-keepattributes Signature
-keepattributes *Annotation*
-keep class * implements java.io.Serializable { *; }

# ---- General Android/Kotlin safety nets ----
-keepattributes Exceptions,InnerClasses
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**

# ---- Cashfree SDK bundles Mozilla Rhino (org.mozilla.javascript) for its
# JS-based JSON conversion utilities. Rhino's JavaToJSONConverters class has
# code paths referencing java.beans.* (BeanInfo, BeanDescriptor, Introspector,
# etc) and javax.script.* (Bindings, ScriptEngineFactory) — these are
# desktop-JVM-only APIs that don't exist in Android's runtime and were never
# on the classpath to begin with, even before minify was turned on. R8 fails
# the build with "Missing classes detected" because it can't verify these
# references, even though they're on a code path Cashfree/Rhino only takes
# when running on a full desktop JVM, never on Android at runtime. -dontwarn
# tells R8 these are known-safe to leave unresolved rather than fail the
# build — this doesn't strip or change any Cashfree/payment functionality,
# it only silences a check for classes that were always absent on Android.
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn org.mozilla.javascript.**
