# Aurum — Language/Flag Fix Package

## Kya hai ismein (sirf fix wali files, koi extra nahi)

```
lib/config/languages.dart              ← NAYA FILE (66 languages, flags, names)
lib/providers/locale_provider.dart     ← REPLACE (ab languages.dart se data leta hai)
lib/screens/settings_language_screen.dart ← REPLACE (real flags + search bar UI)
.github/scripts/auto_translate.py      ← NAYA FILE (auto .arb generator)
.github/workflows/build.yml            ← REPLACE (auto-translate step add kiya)
```

Baaki koi file iss zip me nahi hai — kyunki baaki kisi file ko touch nahi karna tha.

---

## Termux me push karne ke commands

Zip ko apne phone pe extract karne ke baad (ya seedha files copy karke),
apne Aurum repo folder ke andar jaake ye chalao:

```bash
# 1. Apne repo folder me jao
cd ~/Aurum-app-main        # apna actual path daalo agar alag hai

# 2. Fix package ki files repo ke andar unzip/copy karo
#    (agar zip already extract kar chuke ho kahin aur, to bas cp -r use karo
#     us extracted folder se yahan — folder structure already sahi hai)
unzip -o ~/downloads/aurum-language-fix.zip -d .

# 3. Confirm karo kaunsi files badli/nayi hain
git status

# 4. Sab fixed files stage karo
git add lib/config/languages.dart
git add lib/providers/locale_provider.dart
git add lib/screens/settings_language_screen.dart
git add .github/scripts/auto_translate.py
git add .github/workflows/build.yml

# 5. Commit karo
git commit -m "feat: add 66-language support with real flags + auto-translate CI pipeline"

# 6. Push karo
git push origin main        # ya jo bhi tumhari branch hai (master/main)
```

---

## Push ke baad kya hoga

1. GitHub Actions "Build Aurum Music APK" workflow trigger hoga
2. `Auto-translate missing languages` step chalega — 8 naye languages ke
   `.arb` files khud ban jayenge (Google free translate endpoint se)
3. Wo naye `.arb` files khud commit + push ho jayenge repo me
   (commit message: `chore: auto-generate translations for new language(s) [skip ci]`)
4. Normal build (`flutter analyze` → APK build) continue hoga

Pehli push par sirf **8 languages** generate honge (safe batch size —
build time limit ke andar rehne ke liye). Baaki 43 ke liye:

```bash
# Kuch der baad (workflow complete hone ke baad) ek chhota commit push karo
# taaki agla batch trigger ho — koi code change ki zaroorat nahi, khaali
# commit bhi chalega:
git commit --allow-empty -m "chore: trigger next translation batch"
git push
```

Ya GitHub.com pe jaake **Actions tab → Build Aurum Music APK → Run workflow**
button se bhi manually re-run kar sakte ho.

---

## Naya language future me add karna (isके बाद)

`lib/config/languages.dart` khol ke sirf 4 lines add karo:

```dart
// 1. kSupportedLocales list me:
Locale('bn'), // Bengali

// 2. kLocaleDisplayNames map me:
'bn': 'বাংলা',

// 3. kLocaleEnglishNames map me:
'bn': 'Bengali',

// 4. kLocaleFlags map me:
'bn': '🇧🇩',
```

Commit + push. Baaki sab automatic. Koi aur file kabhi nahi chhuni.

---

## Recheck ke liye — ye files verify ho chuki hain

- ✅ `languages.dart` — 67 locale codes, sab 3 maps me entries complete
  (koi missing flag/name nahi, verified via script)
- ✅ `locale_provider.dart` — export ke through `main.dart` aur
  `settings_language_screen.dart` bina touch kiye kaam karte rahenge
- ✅ `settings_language_screen.dart` — real flag emoji, search bar,
  native+English name rows
- ✅ `auto_translate.py` — Python syntax valid, placeholder-protection
  (`{query}`, `{count, plural...}`) offline-tested round-trip 100% sahi
- ✅ `build.yml` — YAML valid, `contents: write` permission add kiya
  hai taaki auto-translate step commit+push kar sake
