import 'song.dart';

/// Status of a single download task.
enum DownloadStatus { queued, downloading, completed, failed, cancelled }

/// Represents one downloaded (or downloading) song.
/// Persisted in Hive box `aurum_downloads`, keyed by song.id.
class DownloadItem {
  final Song song;
  final DownloadStatus status;
  final double progress; // 0.0 - 1.0
  final String? localPath; // set once completed
  final int? fileSizeBytes;
  final DateTime addedAt;

  DownloadItem({
    required this.song,
    required this.status,
    this.progress = 0.0,
    this.localPath,
    this.fileSizeBytes,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  bool get isCompleted => status == DownloadStatus.completed;
  bool get isDownloading => status == DownloadStatus.downloading || status == DownloadStatus.queued;
  bool get isFailed => status == DownloadStatus.failed;

  DownloadItem copyWith({
    DownloadStatus? status,
    double? progress,
    String? localPath,
    int? fileSizeBytes,
  }) {
    return DownloadItem(
      song: song,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      localPath: localPath ?? this.localPath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      addedAt: addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'song': song.toJson(),
    'status': status.name,
    'progress': progress,
    'localPath': localPath,
    'fileSizeBytes': fileSizeBytes,
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
      addedAt: json['addedAt'] != null
          ? DateTime.tryParse(json['addedAt']) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
