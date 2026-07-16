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
