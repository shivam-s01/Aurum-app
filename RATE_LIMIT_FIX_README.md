# Rate-Limit Fix — auto_translate.py

## Kya problem thi

Pehle wali script har EK string ke liye alag translate request bhejti thi
— matlab 1 language = ~709 requests. Google ke free translate endpoint
ne itni requests ek IP se thodi der me dekh kar "429 Too Many Requests"
rate-limit laga diya, isliye tumhara build 21+ minute me sirf 1 language
(Bengali) pe hi atka reh gaya tha aur wo bhi English fallback me chali
gayi thi.

## Kya fix kiya

1. **Batching**: Ab 40 strings ek hi request me bhejta hai (newline se
   joड़कर). Isse 1 language = ~18 requests (709 ki jagah). Rate-limit
   lagne ka chance bahut kam ho gaya.

2. **Har run me sirf 3 languages** (8 ki jagah) — taaki agar kabhi
   rate-limit lage bhi to poora build zyada der tak na atka rahe.

3. **Delay badhaya** — 0.4s se 2s per-request, taaki Google ka server
   requests ko "normal traffic" jaisa treat kare.

4. **Safe fallback** — agar kabhi ek batch fail ho jaye (network issue
   ya mismatch), to wo batch apne-aap per-string translation pe switch
   ho jaata hai, crash nahi hota, translation bhi galat nahi hoti.

## Kya karna hai ab

Sirf ye 1 file replace karo apne repo me:

```
.github/scripts/auto_translate.py
```

Baaki files (languages.dart, locale_provider.dart,
settings_language_screen.dart, build.yml) already sahi hain, unhe
dobara touch nahi karna.

## Termux commands

```bash
cd ~/Aurum-app
cp /sdcard/Download/auto_translate_fix.zip .
unzip -o auto_translate_fix.zip -d .
git add .github/scripts/auto_translate.py
git commit -m "fix: batch translate requests to avoid rate-limit (429)"
git push origin main
```

## Ab kitna time lagega

Har build me 3 languages generate honge, har language ~18 requests
(2s delay ke saath) = ~1 minute per language + network time. Poora
step ab **~3-5 minute** me complete ho jaana chahiye (pehle 21+ minute
lag raha tha aur ek language bhi poori nahi ban paayi thi).

51 baaki languages ke liye ~17 push/re-run lagenge (3 per run) — ya
GitHub Actions "Run workflow" button se bhi manually re-run kar sakte
ho jab chaho.
