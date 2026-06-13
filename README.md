#.   ON THE WAY
# 🎵 Aurum Music

Gold-themed Flutter music streaming app powered by the Aurum backend.

## Stack
- **Flutter** 3.22+ / Dart 3.0+
- **Backend**: `https://aurum-stream.sharmashivam9109.workers.dev`
- **Audio**: `just_audio` + `just_audio_background` + `audio_service`
- **State**: `provider`
- **Package**: `com.aurum.music`

## Features
- 🏠 Home with trending + categorised sections
- 🔍 Search with real-time suggestions (`/api/suggest`)
- 🎵 Mini player with progress bar
- 🎧 Full player with rotating artwork disc
- 🔒 Background audio + lock screen controls
- 📋 Queue management (reorder, remove, play next)
- 🔁 Loop (off / all / one) + Shuffle
- 🎨 Gold (#B89640) + Dark (#050508) theme with Sora font

## Project Structure
```
lib/
├── main.dart
├── theme/aurum_theme.dart
├── models/song.dart
├── services/
│   ├── api_service.dart
│   └── audio_handler.dart
├── providers/player_provider.dart
├── screens/
│   ├── main_shell.dart
│   ├── home_screen.dart
│   ├── search_screen.dart
│   ├── full_player_screen.dart
│   └── queue_screen.dart
└── widgets/
    ├── aurum_artwork.dart
    ├── mini_player.dart
    └── song_tile.dart
```

## Local Build (Termux)

```bash
# Install Flutter via fvm or direct
git clone https://github.com/yourusername/aurum-music
cd aurum-music
flutter pub get
flutter build apk --release
# APK at: build/app/outputs/flutter-apk/app-release.apk
```

## GitHub Actions (Auto APK)

Push to `main` → APK builds automatically.  
Download from **Actions → latest run → Artifacts → aurum-music-apk**

For a release APK, push a tag:
```bash
git tag v1.0.0
git push origin v1.0.0
```

## API Endpoints Used
| Endpoint | Purpose |
|---|---|
| `/api/songs` | Home trending songs |
| `/api/saavn?query=X` | Category sections |
| `/api/search?q=X` | Search results |
| `/api/suggest?q=X` | Autocomplete suggestions |
| `/api/play?id=X` | Resolve stream URL |
| `/api/stream?id=X` | Fallback stream |
