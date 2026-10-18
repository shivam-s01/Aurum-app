/// Blocks abusive Hindi / Hinglish / English / Devanagari text in feedback.
///
/// Approach: normalise the text (lowercase, leet-speak, repeated letters,
/// "m.a.d.a.r" / "m a d a r" obfuscation) and then check
///  - SHORT words ("bc", "mc", "lund") only as whole tokens, so normal
///    words never false-positive.
///  - LONG words ("madarchod", "fuck") as substrings of a token, so
///    "madarchodddd" / "motherfucker" are caught too.
class ProfanityFilter {
  ProfanityFilter._();

  // Whole-token matches only (short / ambiguous inside other words).
  static const _exact = <String>{
    'bc', 'bsdk', 'bkl', 'mkc', 'mdrchd', 'bhosda', 'bhosdi',
    'chut', 'gand', 'gandu', 'gaandu', 'lund', 'lauda', 'loda', 'lawda',
    'randi', 'raand', 'kutta', 'kutti', 'kutiya', 'kamina',
    'kamine', 'kamini', 'harami', 'tatti', 'chutad', 'jhatu', 'bhadwa',
    'bhadwe', 'bhadve', 'dick', 'cock', 'cunt', 'slut', 'whore', 'bitch',
    'bastard', 'asshole', 'stfu', 'fck', 'fuk', 'fvck', 'shit',
    'tmkc', 'tmkb', 'gnd', 'chutia',
  };

  // Matched anywhere inside a token (long enough to be unambiguous).
  static const _contains = <String>{
    'madarchod', 'madharchod', 'maderchod', 'mdarchod', 'madrchod',
    'behenchod', 'bhenchod', 'bhanchod', 'benchod', 'behnchod', 'bahenchod',
    'betichod', 'bhosdike', 'bhosadike', 'bhosdika', 'bhosdiwala',
    'chutiya', 'chutiye', 'chutia', 'chotiya', 'chotiye', 'chotia', 'gandmara', 'gaandmara', 'haramkhor',
    'haramzada', 'haramzade', 'haramjada', 'lundfakir', 'randike',
    'fuck', 'motherfuck', 'asshole', 'bitch', 'bastard',
    // Devanagari
    'मादरचोद', 'बहनचोद', 'भोसड़ी', 'भोसड', 'चूतिया', 'चुतिया', 'गांडू',
    'गाण्डू', 'रंडी', 'हरामी', 'हरामखोर', 'कमीना', 'कमीने', 'बेटीचोद',
    'लौड़ा', 'लवडा', 'चोदू',
  };

  static final _leet = <String, String>{
    '0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't',
    '@': 'a', r'$': 's', '€': 'e',
  };

  static final _strip = RegExp(r"[*#'’`_\-]");
  static final _split = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);
  static final _repeat = RegExp(r'(.)\1+', unicode: true);

  static String _collapse(String s) => s.replaceAllMapped(_repeat, (m) => m[1]!);

  static String _normalise(String raw) {
    final b = StringBuffer();
    for (final ch in raw.toLowerCase().split('')) {
      b.write(_leet[ch] ?? ch);
    }
    return b.toString().replaceAll(_strip, '');
  }

  static List<String> _tokens(String raw) {
    final parts =
        _normalise(raw).split(_split).where((t) => t.isNotEmpty).toList();
    // Merge runs of 3+ single letters: "m a d a r c h o d", "m.a.d.a.r".
    final out = <String>[];
    final run = StringBuffer();
    var runLen = 0;
    void flush() {
      if (runLen >= 3) {
        out.add(run.toString());
      } else {
        // not an obfuscation run — keep the letters as-is
        for (final c in run.toString().split('')) {
          out.add(c);
        }
      }
      run.clear();
      runLen = 0;
    }

    for (final t in parts) {
      if (t.runes.length == 1) {
        run.write(t);
        runLen++;
      } else {
        flush();
        out.add(t);
      }
    }
    flush();
    return out;
  }

  static final Set<String> _exactC = _exact.map(_collapse).toSet();
  static final Set<String> _containsC = _contains.map(_collapse).toSet();

  /// True if [text] contains abusive language.
  static bool containsProfanity(String text) {
    if (text.trim().isEmpty) return false;
    for (final tok in _tokens(text)) {
      final t = _collapse(tok);
      if (_exactC.contains(t)) return true;
      for (final w in _containsC) {
        if (t.contains(w)) return true;
      }
    }
    // Cross-word obfuscation for long words only (avoids "this hit" → shit).
    final squashed =
        _collapse(_normalise(text).replaceAll(_split, ''));
    for (final w in _containsC) {
      if (w.length >= 7 && squashed.contains(w)) return true;
    }
    return false;
  }
}
