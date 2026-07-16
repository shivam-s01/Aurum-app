# ---- Flutter (required, standard) ----
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# ---- This app's own native classes (Kotlin platform channels, MediaSessionService, etc) ----
# These are called from Dart via MethodChannel by string name / reflection-adjacent
# platform channel dispatch, and MediaSessionService/Service subclasses are
# instantiated by the Android OS itself — none of that is visible to R8's static
# analysis, so they must be kept explicitly or the app breaks at runtime with no
# compile-time warning.
-keep class com.aurum.music.** { *; }

# ---- Media3 / ExoPlayer ----
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# ---- NewPipeExtractor + NewValve (YouTube resolution) ----
# Uses reflection-heavy JSON parsing (Jsoup, its own JSON extractor) internally;
# stripping unused-looking methods here breaks parsing of live YouTube responses.
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
-keepattributes SourceFile,LineNumberTable
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
