# Aurum — Recheck: Pause/Resume Downloads (4 files)

Sab 4 files check ki: download_item.dart, app_en.arb, download_provider.dart,
library_screen.dart. Feature hai — download pause/resume + "Downloaded" /
"In progress" tabs + local files search. Overall achha likha tha, lekin
download_provider.dart mein 2 real bugs mile jo maine yahan fix kiye hain.
Baaki 3 files (download_item.dart, app_en.arb, library_screen.dart) clean
hain — koi change nahi kiya, sirf as-is include kiya hai zip mein.

## Fix 1 — pauseDownload() null-crash + state leak (real bug)

**Kahan:** `download_provider.dart` → `pauseDownload()`

**Problem:** `CancelToken` sirf `_runDownload()` ke andar banta hai — aur
Saavn songs ke liye URL resolve hone tak (async step) status `queued`
rehta hai, `isDownloading` getter `queued` ko bhi true count karta hai.
Agar user Pause button dabaye is queued window mein:
1. `_pausedTokens.add(songId)` chal jata hai
2. `_cancelTokens[songId]` abhi tak null hai, to `?.cancel()` silently
   no-op ho jata hai — download ruka nahi, chalta rehta hai
3. `_pausedTokens` mein songId reh jata hai without being cleared
4. Jab wo download baad mein genuinely fail ho ya cancel ho, catch block
   `_pausedTokens.remove()` check karega aur galat se ise "paused" treat
   kar dega — `.part` file forever disk pe reh jayegi, cancel bhi kaam
   nahi karega expected tarike se

**Fix:** Ab pehle live token check karta hai — agar token exist nahi
karta, `pauseDownload()` seedha return kar deta hai (kuch nahi hota),
_pausedTokens mein add hi nahi hota jab tak token safely cancel na ho
sake. Real production impact: kisi bhi Saavn song ko download shuru hote
hi turant pause dabana (bahut common hai jaldi mein) is bug ko trigger
karta.

## Fix 2 — resume path: byte offset silently not saved when server omits Content-Length

**Kahan:** `download_provider.dart` → `_runDownload()` resume branch
(Range-request stream loop)

**Problem:** `bytesDownloaded` sirf `if (total > 0)` block ke andar
persist ho raha tha. Agar resume ke time server Range response mein
Content-Length nahi bhejta (kuch CDNs aisa karte hain especially chunked
transfer encoding ke sath), `total` `-1` reh jata hai aur poore transfer
mein `bytesDownloaded` disk pe kabhi update hi nahi hota.

Agar app is state mein beech mein kill ho jaye (phone ne kill kiya,
user ne swipe kiya), next resume purane (chhote) saved offset se
Range request bhejega — lekin `.part` file mein already usse zyada
bytes pade honge. Result: overlap wale bytes file mein do baar aa
jayenge → corrupt MP3 (crackle/glitch ya poora unplayable file).

**Fix:** Byte offset ab total pata ho ya na ho, dono cases mein
persist hota hai — jab total pata hai to percent-change pe (jaisa
pehle tha), jab pata nahi to har 256KB pe (taaki disk I/O bhi na
spam ho). Progress bar (%) sirf tab update hoga jab total known
ho — UI same rahega jaha CDN Content-Length deta hai, aur jaha nahi
deta wahan bhi ab data-integrity safe hai.

## Baaki sab

- `download_item.dart` — model changes (resolvedUrl, bytesDownloaded,
  paused status) clean hain, no issue.
- `app_en.arb` — sirf naye strings add hue hain, koi placeholder/key
  mismatch nahi mila.
- `library_screen.dart` — naya tabbed Downloads UI (Downloaded / In
  progress) aur Local Files search bar dono theek se wire hue hain.
  Koi dead button, dangling reference, ya missing l10n key nahi mila.
  Pause/Resume/Cancel teeno buttons provider ke sahi methods se juda
  hain aur double-tap bhi safe hai (provider khud current state pe
  guard karta hai).

## Karna kya hai

Ye 4 files apne project mein same path pe copy-paste kar do
(overwrite karega), phir:

    git add -A
    git commit -m "fix: pause/resume download crash + resume byte-offset persistence bug"
    git pull --rebase origin main
    git push

Real device pe verify karne wali cheez: kisi Saavn song ko download
shuru karte hi turant pause dabao — pehle crash/silent-continue hota
tha, ab clean no-op hona chahiye. Resume ka data-integrity fix
runtime mein observe nahi hoga (silent), bas trust karo static
analysis pe — matches jaisa Round-6 notes mein bhi disclaimer tha.
