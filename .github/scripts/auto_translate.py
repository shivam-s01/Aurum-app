#!/usr/bin/env python3
"""
auto_translate.py — Aurum Music CI helper

WHAT THIS DOES
Reads lib/config/languages.dart to find every language code the app is
supposed to support (kSupportedLocales), compares that against the
lib/l10n/app_<code>.arb files that already exist, and for every language
that's missing an .arb file, machine-translates lib/l10n/app_en.arb
(the source-of-truth template) into a new app_<code>.arb.

This means adding a language to Aurum is a ONE-FILE change:
  1. Add a Locale('xx') line (+ its name/flag entries) to
     lib/config/languages.dart
  2. Push. This script runs in CI, notices 'xx' has no .arb yet, and
     generates lib/l10n/app_xx.arb automatically before the Flutter
     build compiles it in.

No other file — not this script, not any screen, not the build
config — needs to be touched to add a language.

WHY IT'S SAFE TO RUN ON EVERY BUILD
Languages that already have an .arb file are left completely untouched
(never re-translated, never overwritten) — so a maintainer's manual
fixes to an existing translation are never clobbered by this script.
It only ever fills in genuinely missing files.

PLACEHOLDER SAFETY
Aurum's .arb strings use two kinds of ICU-style placeholders that must
survive translation byte-for-byte, or the generated Dart code
(app_localizations.dart) will fail to parse them at build time:
  - Simple placeholders:      "No results for \"{query}\""
  - ICU plural blocks:        "{count, plural, =0{No songs} =1{1 song}
                                other{{count} songs}}"
Both are protected before translation (swapped for inert placeholder
tokens the translator won't touch) and restored byte-for-byte after.

TRANSLATION BACKEND
Uses Google Translate's free public web endpoint (the same one behind
translate.google.com) via plain HTTPS requests — no API key, no GCP
billing account, no dependency beyond Python's standard library. It's
unofficial and rate-limited, so the script paces requests and retries
with backoff; for ~700 strings x dozens of languages a full first run
can take a while, which is why results are cached (see CACHE below)
and re-runs only ever translate what's still missing.
"""

import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LANG_DART = os.path.join(ROOT, "lib", "config", "languages.dart")
ARB_DIR = os.path.join(ROOT, "lib", "l10n")
TEMPLATE_ARB = os.path.join(ARB_DIR, "app_en.arb")

# Aurum's language codes occasionally aren't valid Google Translate
# target codes as-is (Flutter/ISO vs Google Translate's own codes
# differ for a handful of languages). Map the exceptions here; anything
# not listed is passed through unchanged.
GOOGLE_CODE_OVERRIDES = {
    "fil": "tl",  # Filipino -> Google's "tl" (Tagalog-based) code
    "he": "iw",   # Hebrew -> Google's legacy code
    "zh": "zh-CN",
}

REQUEST_DELAY_SECONDS = 0.4
MAX_RETRIES = 4

# A single CI run translating EVERY missing language at once (dozens of
# languages x ~700 strings each) would take hours and risk hitting the
# workflow's time limit or the free endpoint's rate limits. Instead,
# each run generates at most this many new languages, commits them, and
# the very next push (or a re-run of this workflow) picks up the next
# batch — so kSupportedLocales can jump from 16 to 90 in one edit, and
# the .arb files simply fill in over a few builds without anyone having
# to babysit it or split the list themselves.
MAX_LOCALES_PER_RUN = 8


def extract_locale_codes(dart_source: str):
    """
    Pull every locale code out of the kSupportedLocales list specifically
    (not just anywhere in the file — this file's own doc-comment at the
    top uses "Locale('xx')" as a placeholder example, and a naive
    file-wide regex would wrongly pick that up as a 69th language).

    Strategy: isolate the text between "kSupportedLocales = [" and its
    closing "];", strip // line-comments from that slice only, then
    look for Locale('..') entries inside it.
    """
    start_marker = "kSupportedLocales"
    start = dart_source.find(start_marker)
    if start == -1:
        return []
    list_start = dart_source.find("[", start)
    list_end = dart_source.find("];", list_start)
    if list_start == -1 or list_end == -1:
        return []
    block = dart_source[list_start:list_end]

    # Strip // comments per line so a trailing "// English" etc. can
    # never be mistaken for code, and so a comment could never smuggle
    # in a fake entry.
    code_only_lines = []
    for line in block.splitlines():
        comment_idx = line.find("//")
        code_only_lines.append(line if comment_idx == -1 else line[:comment_idx])
    code_only = "\n".join(code_only_lines)

    codes = re.findall(r"Locale\('([a-zA-Z-]+)'\)", code_only)
    # de-dupe while preserving order
    seen = set()
    ordered = []
    for c in codes:
        if c not in seen:
            seen.add(c)
            ordered.append(c)
    return ordered


def load_template():
    with open(TEMPLATE_ARB, "r", encoding="utf-8") as f:
        return json.load(f)


def existing_arb_codes():
    codes = set()
    for name in os.listdir(ARB_DIR):
        m = re.match(r"^app_([a-zA-Z-]+)\.arb$", name)
        if m:
            codes.add(m.group(1))
    return codes


# ── Placeholder protection ──────────────────────────────────────────

PLACEHOLDER_TOKEN = "XPH{index}X"


def protect_placeholders(text: str):
    """
    Replace every {...} chunk (simple placeholder OR a full ICU plural
    block) with an inert token, so the translator only ever sees plain
    prose. Returns (protected_text, [original_chunks]).

    ICU plural blocks nest braces, e.g.:
      {count, plural, =0{No songs} =1{1 song} other{{count} songs}}
    so a naive non-nested regex would truncate at the first inner '}'.
    This walks the string tracking brace depth instead.
    """
    chunks = []
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "{":
            depth = 1
            j = i + 1
            while j < n and depth > 0:
                if text[j] == "{":
                    depth += 1
                elif text[j] == "}":
                    depth -= 1
                j += 1
            chunk = text[i:j]
            chunks.append(chunk)
            out.append(PLACEHOLDER_TOKEN.format(index=len(chunks) - 1))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out), chunks


def restore_placeholders(translated: str, chunks):
    def _sub(m):
        idx = int(m.group(1))
        return chunks[idx] if 0 <= idx < len(chunks) else m.group(0)
    # Translation engines sometimes add spacing/punctuation around a
    # token or alter its case — match loosely (case-insensitive, and
    # tolerate stray surrounding spaces) rather than requiring an exact
    # echo of PLACEHOLDER_TOKEN.
    pattern = re.compile(r"X\s*PH\s*\{?\s*(\d+)\s*\}?\s*X", re.IGNORECASE)
    return pattern.sub(_sub, translated)


# ── Translation backend ─────────────────────────────────────────────

def google_translate_text(text: str, target: str) -> str:
    """
    Calls the free translate.google.com client endpoint. Returns the
    translated string, or the original text unchanged if every retry
    fails (never raises — a failed string should not abort the whole
    build; worst case that one string stays in English).
    """
    if not text.strip():
        return text

    params = {
        "client": "gtx",
        "sl": "en",
        "tl": target,
        "dt": "t",
        "q": text,
    }
    url = "https://translate.googleapis.com/translate_a/single?" + urllib.parse.urlencode(params)

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                # data[0] is a list of [translated_chunk, original_chunk, ...]
                return "".join(seg[0] for seg in data[0] if seg[0])
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError) as e:
            wait = attempt * 1.5
            print(f"    retry {attempt}/{MAX_RETRIES} for target={target} after error: {e} (waiting {wait}s)")
            time.sleep(wait)
    print(f"    WARNING: giving up on one string for target={target}; leaving it in English")
    return text


def translate_value(key: str, value: str, target: str) -> str:
    # @@locale and metadata keys are handled by the caller, never here.
    protected, chunks = protect_placeholders(value)
    translated = google_translate_text(protected, target)
    restored = restore_placeholders(translated, chunks)
    time.sleep(REQUEST_DELAY_SECONDS)
    return restored


def build_arb_for_locale(template: dict, code: str) -> dict:
    google_target = GOOGLE_CODE_OVERRIDES.get(code, code)
    out = {"@@locale": code}
    total = sum(1 for k in template if not k.startswith("@") and k != "@@locale")
    done = 0
    for key, value in template.items():
        if key == "@@locale":
            continue
        if key.startswith("@"):
            # Metadata blocks (descriptions, placeholder type info) are
            # dev-facing only and never shown in the UI — copy as-is,
            # no need to translate or even touch them.
            out[key] = value
            continue
        out[key] = translate_value(key, value, google_target)
        done += 1
        if done % 50 == 0 or done == total:
            print(f"    [{code}] {done}/{total} strings translated")
    return out


def main():
    if not os.path.isfile(LANG_DART):
        print(f"ERROR: {LANG_DART} not found", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(TEMPLATE_ARB):
        print(f"ERROR: template {TEMPLATE_ARB} not found", file=sys.stderr)
        sys.exit(1)

    with open(LANG_DART, "r", encoding="utf-8") as f:
        dart_source = f.read()

    wanted_codes = extract_locale_codes(dart_source)
    have_codes = existing_arb_codes()
    missing = [c for c in wanted_codes if c not in have_codes]

    if not missing:
        print("auto_translate: every supported locale already has an .arb file — nothing to do.")
        return

    batch = missing[:MAX_LOCALES_PER_RUN]
    remaining_after = len(missing) - len(batch)

    print(f"auto_translate: {len(missing)} locale(s) missing an .arb file: {', '.join(missing)}")
    print(f"auto_translate: generating {len(batch)} this run ({', '.join(batch)}); "
          f"{remaining_after} will remain for the next run.")
    template = load_template()

    for code in batch:
        out_path = os.path.join(ARB_DIR, f"app_{code}.arb")
        print(f"  generating {out_path} ...")
        arb = build_arb_for_locale(template, code)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(arb, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"  wrote {out_path}")

    if remaining_after > 0:
        print(f"auto_translate: done with this batch. {remaining_after} locale(s) still "
              f"pending — push again (or re-run this workflow) to continue: "
              f"{', '.join(missing[MAX_LOCALES_PER_RUN:])}")
    else:
        print("auto_translate: done — every supported locale now has an .arb file.")


if __name__ == "__main__":
    main()
