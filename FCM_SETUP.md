# Push notifications ("Update available") — one-time setup

Yeh setup **free** hai (Firebase Spark plan), aur sirf ek baar karna hai.
Isके baad har `[release]` build automatically sab users ko "Update
available" notification bhej degi — app band ho ya open, dono mein.

## 1. Firebase project banao

1. https://console.firebase.google.com kholo → **Add project** → naam do
   (e.g. "Aurum Music") → analytics on/off jo chaho.
2. Project ke andar → **Project settings** (gear icon) → **Your apps** →
   **Add app** → Android choose karo.
3. Package name mein exactly ye daalo: `com.aurum.music`
4. `google-services.json` download hoga — isse
   `android/app/google-services.json` par rakho (yahi filename, yahi
   path). Ye file **git mein commit karni hai** — isme koi secret nahi
   hota, ye sirf public app-identifier hai (Google ke docs confirm karte
   hain ye safe hai commit karna).

## 2. GitHub Actions ke liye service account key

Ye wo secret hai jo CI ko FCM ko notification bhejne ki permission deta
hai — isse **kabhi commit mat karo**, sirf GitHub Secrets mein daalo.

1. Firebase console → Project settings → **Service accounts** tab.
2. **Generate new private key** button dabao → ek `.json` file download
   hogi.
3. GitHub repo → **Settings → Secrets and variables → Actions → New
   repository secret**.
4. Name: `FIREBASE_SERVICE_ACCOUNT`
5. Value: us `.json` file ka **poora content** paste kar do.
6. Save.

Bas itna hi. Agla `[release]` commit push karoge, build.yml khud-ba-khud:
- APK banayega (jaisa pehle se hota tha)
- GitHub release publish karega (jaisa pehle se hota tha)
- **Naya step:** sab devices ko "Update available" push bhej dega

## Test kaise karo

- Ek chhota commit karo jisme commit message mein `[release]` ho.
- Build complete hone ke baad, tumhare phone (jaha app install hai, aur
  jo internet se connected ho, app khula ho ya band) par kuch minutes
  mein notification aani chahiye.
- Agar `FIREBASE_SERVICE_ACCOUNT` secret nahi mila hoga, wo step sirf
  skip ho jayega (build fail nahi hoga) — GitHub Actions log mein
  "skipping push notification" line dikhegi.

## Agar setup nahi karna abhi

Kuch bhi tootega nahi — `google-services.json` na ho to build usually
chalti rahegi (plugin conditionally apply hota hai), aur app mein
`UpdatePushService.init()` khud fail-soft ho ke silently disable ho
jayega. Baaki sab (download notifications, in-app update check) waise
hi chalega jaise pehle chalta tha.
