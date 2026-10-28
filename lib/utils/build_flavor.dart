// Build-time constants injected by CI via --dart-define.
//
// BUILD_LABEL is a short, human-friendly build id (IST date yymmdd + CI
// run number, e.g. "261027.142"). Display only — the real Android
// versionCode is untouched. Empty for local/debug builds.
const String kBuildLabel = String.fromEnvironment('BUILD_LABEL');

// True only for the Play Store (AAB) build, set by the manual "Play Store"
// workflow. Play builds must not self-update from GitHub, so the in-app
// update check is skipped. The website APK is unaffected (default false).
const bool kPlayBuild = bool.fromEnvironment('PLAY_BUILD');
