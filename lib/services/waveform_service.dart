import 'dart:io';
import 'dart:math' as math;
import 'package:just_waveform/just_waveform.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

class WaveformService {
  static List<double> generateFallback(String seed, {int bars = 60}) {
    final h = md5.convert(utf8.encode(seed)).toString();
    final seedInt = h.substring(0, 8).codeUnits.fold(0, (a, b) => a + b);
    final rnd = math.Random(seedInt);
    final List<double> vals = [];
    double last = 0.5;
    for (int i = 0; i < bars; i++) {
      final drift = (rnd.nextDouble() - 0.5) * 0.35;
      last = (last + drift).clamp(0.15, 1.0);
      vals.add(last);
    }
    return vals;
  }

  static Future<List<double>?> getWaveform(String audioPathOrUrl, {required bool isLocal}) async {
    try {
      final dir = await getTemporaryDirectory();
      final hash = md5.convert(utf8.encode(audioPathOrUrl)).toString();
      final wavePath = '${dir.path}/wf_$hash.wave';
      final waveFile = File(wavePath);

      if (!isLocal) return generateFallback(audioPathOrUrl);

      final progressStream = JustWaveform.extract(
        audioInFile: File(audioPathOrUrl),
        waveOutFile: waveFile,
      );

      WaveformProgress? last;
      await for (final msg in progressStream) {
        last = msg;
      }

      if (last?.waveform == null) return generateFallback(audioPathOrUrl);
      final wf = last!.waveform!;
      final len = wf.length;
      if (len == 0) return generateFallback(audioPathOrUrl);

      const targetBars = 60;
      final step = (len / targetBars).ceil().clamp(1, len);
      final List<double> bars = [];
      for (int i = 0; i < len; i += step) {
        int minV = 0, maxV = 0;
        for (int j = i; j < (i + step).clamp(0, len); j++) {
          final v = wf.getPixelMax(j);
          if (v > maxV) maxV = v;
          final m = wf.getPixelMin(j);
          if (m < minV) minV = m;
        }
        bars.add((maxV - minV).abs().toDouble());
      }

      final maxBar = bars.reduce((a, b) => a > b ? a : b);
      if (maxBar <= 0) return generateFallback(audioPathOrUrl);
      return bars.map((v) => (v / maxBar).clamp(0.08, 1.0)).toList();
    } catch (_) {
      return generateFallback(audioPathOrUrl);
    }
  }
}
