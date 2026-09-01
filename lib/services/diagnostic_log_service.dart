// =============================================================================
// FILE: lib/services/diagnostic_log_service.dart
// PURPOSE: Dart-side bridge to AurumDiagnosticLog.kt — forwards network
// errors into the same on-device log file as crashes/ANR/offload status,
// and exposes export/share/clear for the Settings → Diagnostic Logs tile.
// See AurumDiagnosticLog.kt for the full design (rotating file, single
// writer thread, crash-safe synchronous write path).
// =============================================================================

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

class DiagnosticLogService {
  DiagnosticLogService._();

  static const MethodChannel _channel = MethodChannel('com.aurum.music/media_store');

  /// Fire-and-forget — never awaited, never throws, so a logging call
  /// itself can never become a new source of errors or add latency to
  /// whatever network call it's reporting on.
  static void logNetworkError(String context, String message) {
    _channel.invokeMethod('logNetworkError', {
      'context': context,
      'message': message,
    }).catchError((_) {
      // Logging the logger's own failure would risk a loop — silently
      // drop instead. The in-app log is a best-effort diagnostic aid,
      // not a guaranteed-delivery system.
    });
  }

  static Future<String?> _logFilePath() async {
    try {
      return await _channel.invokeMethod<String>('getDiagnosticLogPath');
    } catch (_) {
      return null;
    }
  }

  /// Returns the current log contents, or null if nothing has been
  /// logged yet / the file couldn't be read.
  static Future<String?> readLog() async {
    final path = await _logFilePath();
    if (path == null) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Opens the OS share sheet with the raw log file attached — the
  /// simplest reliable way to get it off the phone (WhatsApp, email,
  /// paste into a GitHub Issue, etc.) without needing adb.
  static Future<bool> shareLog() async {
    final path = await _logFilePath();
    if (path == null) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      await Share.shareXFiles(
        [XFile(path)],
        subject: 'Aurum Music — Diagnostic Log',
        text: 'Diagnostic log exported from Aurum Music.',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearLog() async {
    try {
      await _channel.invokeMethod('clearDiagnosticLog');
    } catch (_) {
      // Best-effort — nothing more to do if this fails.
    }
  }
}
