# Aurum — Fix Patch v6 (pre-release audit)

12 files total. Same paths jaise original repo — extract karke apne
project ke upar copy-paste kar do (overwrite karega).

## Ek honest baat pehle
Main Flutter build/run karke actually test nahi kar sakta (mere paas
SDK/device nahi hai yahan) — sirf code deeply padh kar static analysis
karta hu. Jo bugs maine fix kiye wo genuinely concrete aur high-confidence
hain (main dikha sakta hu exactly kya galat tha aur kyun), lekin **"1%
bhi dikkat nahi aayegi" ki 100% guarantee nahi de sakta** — kisi specific
device/OEM/Android version ka koi real-device-only issue ho sakta hai jo
sirf actual testing se pata chalega. Jo bhi verify kar sakta tha, wo kiya.

## Round 6 — cold start ka ek aur chhota sa hidden cost

### lib/services/audio_prefs.dart
**Issue:** `AudioPrefs.load()` ke andar ek line thi —
`await pushStopOnSwipeToNative(...)` — jo ek real native
(Kotlin) platform-channel call karti hai. Ye call khud chhoti hai, lekin
`AudioPrefs.load()` ko `main.dart` mein `runApp()` se **pehle** `await`
kiya jata hai — matlab ye bhi cold-start ke blocking window mein baithi
thi, waise hi jaise Round 5 wala `DownloadProvider` bug tha, bas chhoti
scale par.
**Fix:** Isko `unawaited()` kar diya (fire-and-forget) — native side ko
ye value sirf tab tak pahुnchni chahiye jab tak user app ko Recents mein
swipe na kare, jo cold start se kaafi baad hoti hai. Koi correctness
impact nahi, bas ek aur chhota blocking round-trip cold start se hata
diya.

### Poore app mein aur deeply check kiya
- **Splash screen (2.7s):** Ye intentional brand animation hai, bug
  nahi — single lightweight AnimationController, koi heavy sync kaam
  nahi.
- **MainActivity.kt / Android native side:** `bindMediaSessionService()`
  check ki — `startService()`/`bindService()` dono genuinely async
  Android APIs hain, koi blocking call nahi mila.
- **AndroidManifest.xml:** Sirf standard FileProvider + widget
  declarations — koi heavy auto-init ContentProvider nahi.
- **build.gradle:** `minifyEnabled true` + `shrinkResources true`
  already sahi se set hai release ke liye — ye cold-start classloading
  time ke liye already achi practice hai.
- **Hive boxes (7 total):** Sab independently, parallel open hote hain,
  koi unbounded growth risk nahi (recently-played history already
  capped hai).
- **Permission denial handling:** Agar local music permission deny ho
  jaaye, app crash nahi karta — proper `LibraryStatus.noPermission`
  state hai, graceful hai.

---

## Pichle rounds (recap, sab already is zip mein)
- **Round 5:** `download_provider.dart` — asli cold-start hang fix
  (redundant `NotificationService.init()` jo pehla frame paint hone se
  pehle ek system permission dialog fire kar raha tha).
- **Round 4:** `main.dart` — theme/accent color smooth cross-fade
  (`AnimatedTheme`).
- **Round 3:** Language change + cache/downloads clear — dono jagah ab
  proper loading spinner.
- **Round 2:** Song fail hone par ab proper error + RETRY button.
- **Round 1:** Green flash bug, offline/local-song playback fix, 3
  jagah crash-risk `mounted` check fixes.

## Abhi bhi baaki (out of scope, pehle bhi bataya tha)
Shorts feature + kuch dialogs 16 languages mein translate nahi hue —
bina verify kiye guess karke translate nahi kar sakta.

## Suggestion
Ye sab lagane ke baad ek baar khud real device par cold start test kar
lena (especially low-end/2GB RAM device agar available ho) — wahi sabse
pakka tarika hai 100% confirm karne ka ki ab smooth hai.
