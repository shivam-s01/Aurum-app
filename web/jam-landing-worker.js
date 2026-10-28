// ─────────────────────────────────────────────────────────────────────────
// Astra Jam invite page  →  https://astra.mmusic.workers.dev/jam/<CODE>
//
// Add to your EXISTING Worker (the one serving /privacy and /terms):
//   1) paste jamLanding() below into the file
//   2) inside your fetch handler, before the other routes:
//        const url = new URL(request.url);
//        if (url.pathname.startsWith('/jam/')) return jamLanding(url);
//   3) set DOWNLOAD_URL to your Astra download page / APK link.
//
// What it does: on a phone with Astra installed, the button opens the Jam
// join screen directly; without Astra it falls back to DOWNLOAD_URL.
// ─────────────────────────────────────────────────────────────────────────
const DOWNLOAD_URL = 'https://astra.mmusic.workers.dev/';
const ANDROID_PACKAGE = 'com.aurum.music';

function jamLanding(url) {
  const code = (url.pathname.split('/')[2] || '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '')
    .slice(0, 6);
  if (code.length !== 6) {
    return new Response('Not found', {
      status: 404,
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
    });
  }
  const full = 'ASTRA-' + code;
  const fallback = encodeURIComponent(DOWNLOAD_URL);
  const intent =
    'intent://jam/' + code +
    '#Intent;scheme=astra;package=' + ANDROID_PACKAGE +
    ';S.browser_fallback_url=' + fallback + ';end';

  const html = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Join my Astra Jam</title>
<meta property="og:title" content="Join my Astra Jam">
<meta property="og:description" content="Listen together, in perfect sync. Code: ${full}">
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#13121c;color:#f0ebd8;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
  main{width:min(420px,92vw);text-align:center;padding:28px 22px}
  h1{font-size:26px;margin:0 0 6px}
  p{color:#8a8a9a;margin:6px 0 22px;line-height:1.4}
  .code{display:inline-block;font-weight:800;letter-spacing:2px;font-size:22px;color:#9b7ede;
        background:#1b1927;border:1px solid #2e2b3c;border-radius:14px;padding:12px 18px;margin-bottom:22px}
  a.btn{display:block;background:#9b7ede;color:#fff;text-decoration:none;font-weight:700;
        border-radius:16px;padding:16px;margin-bottom:12px}
  a.alt{color:#8a8a9a;font-size:14px}
</style></head>
<body><main>
  <h1>You\u2019re invited to an Astra Jam</h1>
  <p>Listen together with friends, in perfect sync.</p>
  <div class="code">${full}</div>
  <a class="btn" href="${intent}">Open in Astra</a>
  <a class="alt" href="${DOWNLOAD_URL}">Don\u2019t have Astra? Download it</a>
</main></body></html>`;

  return new Response(html, {
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      'x-frame-options': 'DENY',
    },
  });
}
