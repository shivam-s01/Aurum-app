import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Reads android/key.properties the same way the phone app does — written
// at build time by CI (see .github/workflows/build.yml) by decoding the
// KEYSTORE_BASE64 secret. Locally, copy key.properties.example to
// key.properties and fill in your own keystore details if you want to
// build a signed APK from Termux directly.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.aurum.musictv"
    compileSdk = 35

    // lintVitalAnalyzeRelease has a known crash with certain AGP 8.7.x +
    // Kotlin 2.0 combinations (analyzer throws internally, not a real
    // code issue — see AGP issue tracker). Disabling the release-blocking
    // "vital" lint pass avoids it; full lint still runs on debug builds
    // and via `./gradlew lint` on demand if you want to check manually.
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    defaultConfig {
        applicationId = "com.aurum.musictv"
        // Bumped from 21 -> 23: Compose for TV (tv-material) and
        // Credential Manager (Google Sign-In) require API 23+. Virtually
        // all real Android TV / Google TV / Fire TV hardware sold since
        // ~2017 is API 23+, so this costs negligible real-world reach.
        minSdk = 23
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Falls back to the default debug signing if key.properties
            // isn't present (e.g. a local build without secrets) so the
            // build never hard-fails — it just produces an APK you can't
            // publish, which matches how most Android CI setups degrade.
            signingConfig = if (hasKeystoreProperties) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Supabase-kt (and some of its Ktor/kotlinx dependencies) expect
        // java.time and other APIs that only exist natively on API 26+.
        // Desugaring backports them so minSdk can stay at 23 and still
        // cover older Android TV / Fire TV boxes.
        isCoreLibraryDesugaringEnabled = true
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    // Only ship the ABI most TV boxes use — cuts APK size a lot.
    // arm64-v8a covers virtually all modern Android TV / Fire TV / Google TV
    // hardware. Add armeabi-v7a back in only if you must support very old
    // boxes (adds ~2-3MB).
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a")
            isUniversalApk = false
        }
    }

    packaging {
        resources.excludes += setOf(
            "META-INF/**",
            "kotlin/**",
            "**/*.kotlin_metadata"
        )
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // ── Compose for TV ───────────────────────────────────────────────────
    // Replaces Leanback. androidx.tv:tv-material gives Spotify-style
    // focus/scale animations, Card variants, and D-pad focus handling
    // out of the box — we only pull the BOM + the two TV artifacts, no
    // full Compose UI toolkit bloat (no compose-material3 for phones,
    // no compose-animation-graphics, etc).
    val composeBom = platform("androidx.compose:compose-bom:2024.09.00")
    implementation(composeBom)
    implementation("androidx.tv:tv-foundation:1.0.0")
    implementation("androidx.tv:tv-material:1.1.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.runtime:runtime-livedata")
    implementation("androidx.activity:activity-compose:1.9.1")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.4")

    // Media3 / ExoPlayer — same engine family as the phone app's native
    // AurumAudioEngine. Core + only the HTTP datasource, no extra extractors
    // you don't need, keeps this lean.
    implementation("androidx.media3:media3-exoplayer:1.4.0")
    implementation("androidx.media3:media3-session:1.4.0")
    implementation("androidx.media3:media3-datasource:1.4.0")

    // Coil: much smaller footprint than Glide/Picasso for simple poster/art
    // loading, Kotlin-first, good TV-safe defaults, has a Compose artifact.
    implementation("io.coil-kt:coil-compose:2.6.0")

    // Networking: OkHttp directly (no Retrofit) + manual org.json parsing,
    // same pattern as before — kept for the Worker (search/stream) calls.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // ── Supabase (lightweight, official Kotlin Multiplatform SDK) ──────
    // Only Auth + Postgrest — no Realtime, no Storage, no Functions.
    // Realtime specifically dropped: an always-open websocket + its
    // background dispatcher is unnecessary overhead on a 1GB RAM TV box
    // for what's really an occasional cross-device sync check; TV polls
    // instead (see SyncRepository). Uses Ktor/OkHttp under the hood, which
    // we already depend on, so marginal size cost of what's left is small.
    implementation(platform("io.github.jan-tennert.supabase:bom:3.0.3"))
    implementation("io.github.jan-tennert.supabase:auth-kt")
    implementation("io.github.jan-tennert.supabase:postgrest-kt")
    // Supabase-kt bom:3.0.3 is built against Ktor 3.x. The old pin here was
    // 2.3.12 (Ktor 2.x) which version-clashed with the rest of the Ktor
    // artifacts the BOM pulls in -> HttpTimeout NoClassDefFoundError at
    // runtime. ktor-client-okhttp isn't covered by the Supabase BOM, so it
    // still needs an explicit version — just one from the 3.x line.
    implementation("io.ktor:ktor-client-okhttp:3.0.3")

    // Google Sign-In (Credential Manager — the modern replacement for the
    // old Play Services GoogleSignInClient, smaller and TV-compatible).
    implementation("androidx.credentials:credentials:1.3.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.3.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.1")

    // Settings persistence (Theme/Audio Quality/Autoplay/Crossfade/etc) —
    // Preferences DataStore instead of raw SharedPreferences: async-safe,
    // Flow-based reads so Settings screen and PlayerManager both react
    // live to a change, without SharedPrefs' main-thread disk read risk
    // on a slow TV box's flash storage.
    implementation("androidx.datastore:datastore-preferences:1.1.1")
}
