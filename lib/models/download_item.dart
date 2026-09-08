import 'song.dart';

/// Status of a single download task.
enum DownloadStatus { queued, downloading, paused, completed, failed, cancelled }

/// Represents one downloaded (or downloading) song.
/// Persisted in Hive box `aurum_downloads`, keyed by song.id.
class DownloadItem {
  final Song song;
  final DownloadStatus status;
  final double progress; // 0.0 - 1.0
  final String? localPath; // set once completed
  final int? fileSizeBytes;
  final DateTime addedAt;
  // Pause/resume support: the stream URL resolved for this download (once
  // known) so resuming doesn't need to re-resolve it (a fresh resolve can
  // return a different CDN URL than the one already partially downloaded
  // against), and how many bytes of the `.part` file are already on disk
  // so resume can send a `Range: bytes=<bytesDownloaded>-` request instead
  // of restarting from zero.
  final String? resolvedUrl;
  final int bytesDownloaded;

  DownloadItem({
    required this.song,
    required this.status,
    this.progress = 0.0,
    this.localPath,
    this.fileSizeBytes,
    this.resolvedUrl,
    this.bytesDownloaded = 0,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  bool get isCompleted => status == DownloadStatus.completed;
  bool get isDownloading => status == DownloadStatus.downloading || status == DownloadStatus.queued;
  bool get isPaused => status == DownloadStatus.paused;
  bool get isFailed => status == DownloadStatus.failed;

  DownloadItem copyWith({
    DownloadStatus? status,
    double? progress,
    String? localPath,
    int? fileSizeBytes,
    String? resolvedUrl,
    int? bytesDownloaded,
  }) {
    return DownloadItem(
      song: song,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      localPath: localPath ?? this.localPath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      resolvedUrl: resolvedUrl ?? this.resolvedUrl,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      addedAt: addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'song': song.toJson(),
    'status': status.name,
    'progress': progress,
    'localPath': localPath,
    'fileSizeBytes': fileSizeBytes,
    'resolvedUrl': resolvedUrl,
    'bytesDownloaded': bytesDownloaded,
    'addedAt': addedAt.toIso8601String(),
  };

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status']?.toString();
    final status = DownloadStatus.values.firstWhere(
      (s) => s.name == statusStr,
      orElse: () => DownloadStatus.failed,
    );
    return DownloadItem(
      song: Song.fromJson(Map<String, dynamic>.from(json['song'])),
      status: status,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      localPath: json['localPath'],
      fileSizeBytes: json['fileSizeBytes'],
      resolvedUrl: json['resolvedUrl'],
      bytesDownloaded: (json['bytesDownloaded'] as num?)?.toInt() ?? 0,
      addedAt: json['addedAt'] != null
          ? DateTime.tryParse(json['addedAt']) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
