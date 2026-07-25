// =============================================================================
// FILE: lib/utils/devanagari_transliterator.dart
// PROJECT: Aurum Music
//
// Lightweight, dependency-free Devanagari -> Roman script transliterator.
// Purely a character/glyph mapping table (consonants, vowel signs (matras),
// conjuncts via virama, digits, punctuation) — the same category of thing as
// a font encoding converter. No lyrics text or copyrighted content is
// embedded here; this only maps Unicode code points to Latin letters so
// already-fetched lyrics can be displayed in Roman script for users who
// prefer reading Hindi/Hinglish in Latin letters instead of Devanagari.
//
// Written from scratch (no GPL/third-party transliteration package) so it
// carries no GPL license obligations for the app that uses it.
//
// This is a practical "Hinglish-style" romanization, not strict academic
// IAST — it favors how Hindi speakers commonly type Hinglish (e.g. "ph"
// dropped in favor of common usage patterns where relevant) over
// diacritic-heavy scholarly transliteration.
// =============================================================================

import 'package:characters/characters.dart';

class DevanagariTransliterator {
  DevanagariTransliterator._();

  // Independent vowels
  static const Map<String, String> _vowels = {
    'अ': 'a', 'आ': 'aa', 'इ': 'i', 'ई': 'ee', 'उ': 'u', 'ऊ': 'oo',
    'ऋ': 'ri', 'ए': 'e', 'ऐ': 'ai', 'ओ': 'o', 'औ': 'au',
    'ां': 'an', 'ऑ': 'o',
  };

  // Vowel signs (matras) — attached to a consonant
  static const Map<String, String> _matras = {
    'ा': 'aa', 'ि': 'i', 'ी': 'ee', 'ु': 'u', 'ू': 'oo',
    'ृ': 'ri', 'े': 'e', 'ै': 'ai', 'ो': 'o', 'ौ': 'au',
    'ं': 'n', 'ँ': 'n', 'ः': 'h', '़': '',
  };

  // Consonants (with their inherent "a" already included — stripped via
  // virama handling below when followed by another consonant or the end
  // of a word with virama present)
  static const Map<String, String> _consonants = {
    'क': 'k', 'ख': 'kh', 'ग': 'g', 'घ': 'gh', 'ङ': 'ng',
    'च': 'ch', 'छ': 'chh', 'ज': 'j', 'झ': 'jh', 'ञ': 'ny',
    'ट': 't', 'ठ': 'th', 'ड': 'd', 'ढ': 'dh', 'ण': 'n',
    'त': 't', 'थ': 'th', 'द': 'd', 'ध': 'dh', 'न': 'n',
    'प': 'p', 'फ': 'f', 'ब': 'b', 'भ': 'bh', 'म': 'm',
    'य': 'y', 'र': 'r', 'ल': 'l', 'व': 'v', 'श': 'sh',
    'ष': 'sh', 'स': 's', 'ह': 'h', 'क्ष': 'ksh', 'त्र': 'tr',
    'ज्ञ': 'gy', 'ड़': 'r', 'ढ़': 'rh',
  };

  static const String _virama = '्';
  static const Map<String, String> _digits = {
    '०': '0', '१': '1', '२': '2', '३': '3', '४': '4',
    '५': '5', '६': '6', '७': '7', '८': '8', '९': '9',
  };

  /// True if [text] contains any Devanagari code points (U+0900-U+097F).
  static bool containsDevanagari(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x0900 && rune <= 0x097F) return true;
    }
    return false;
  }

  /// Transliterates Devanagari text to a readable Roman/Hinglish string.
  /// Non-Devanagari characters (Latin letters, punctuation, numbers,
  /// existing English words mixed into the line) pass through unchanged,
  /// so mixed Hindi/English lines romanize only the Devanagari portion.
  static String transliterate(String text) {
    if (text.isEmpty || !containsDevanagari(text)) return text;

    final buffer = StringBuffer();
    final chars = text.characters.toList();
    var i = 0;

    while (i < chars.length) {
      final ch = chars[i];

      // Multi-character consonant clusters (क्ष, त्र, ज्ञ) checked first.
      String? multiMatch;
      for (final cluster in ['क्ष', 'त्र', 'ज्ञ']) {
        if (i + cluster.characters.length <= chars.length &&
            chars.sublist(i, i + cluster.characters.length).join() == cluster) {
          multiMatch = cluster;
          break;
        }
      }

      if (multiMatch != null) {
        buffer.write(_consonants[multiMatch]);
        i += multiMatch.characters.length;
        // Check what follows: matra, virama, or inherent 'a'
        i = _handleFollowing(chars, i, buffer);
        continue;
      }

      if (_consonants.containsKey(ch)) {
        buffer.write(_consonants[ch]);
        i++;
        i = _handleFollowing(chars, i, buffer);
        continue;
      }

      if (_vowels.containsKey(ch)) {
        buffer.write(_vowels[ch]);
        i++;
        continue;
      }

      if (_digits.containsKey(ch)) {
        buffer.write(_digits[ch]);
        i++;
        continue;
      }

      if (ch == _virama) {
        // Bare virama with no preceding consonant already handled — skip.
        i++;
        continue;
      }

      if (ch == '।' || ch == '॥') {
        buffer.write('.');
        i++;
        continue;
      }

      // Anything else (Latin letters, spaces, punctuation, emoji) passes
      // through unchanged.
      buffer.write(ch);
      i++;
    }

    return buffer.toString();
  }

  /// After writing a consonant's base sound, decides whether to add the
  /// inherent "a", apply a following matra, or suppress the vowel entirely
  /// (virama / conjunct). Returns the new index to continue from.
  static int _handleFollowing(List<String> chars, int i, StringBuffer buffer) {
    if (i >= chars.length) {
      // End of word after a consonant — Hinglish convention drops the
      // trailing inherent "a" for a more natural read (e.g. "प्यार" reads
      // as "pyaar", not "pyaara").
      return i;
    }

    final next = chars[i];

    if (next == _virama) {
      // Virama suppresses the inherent vowel entirely (conjunct/halant) —
      // write nothing, move past the virama.
      return i + 1;
    }

    if (_matras.containsKey(next)) {
      buffer.write(_matras[next]);
      return i + 1;
    }

    // No matra/virama follows — a plain consonant standing alone still
    // needs a vowel sound in the middle of a word, but trailing inherent
    // "a" at word boundaries is commonly dropped in Hinglish. We keep it
    // simple and always add a short "a" here (mid-word); the end-of-word
    // case above already returns early without one when nothing follows
    // at all. This is a readability heuristic, not strict linguistics.
    buffer.write('a');
    return i;
  }
}
