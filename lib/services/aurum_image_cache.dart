import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'audio_prefs.dart';

/// AurumImageCache — size-bounded disk cache for network artwork.
///
/// Data Saver ON: every downloaded thumbnail is treated as valid for 30
/// days (ignores the CDN's short max-age), so cold start re-requests
/// nothing. Data Saver OFF: behaves exactly as before (server max-age).
class AurumImageCache extends CacheManager {
  static const key = 'aurumImageCache';
  static final AurumImageCache _instance = AurumImageCache._();
  factory AurumImageCache() => _instance;

  AurumImageCache._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 14),
            maxNrOfCacheObjects: 4000,
            fileService: _SaverAwareFileService(),
          ),
        );
}

class _SaverAwareFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final res = await super.get(url, headers: headers);
    if (!AudioPrefs.dataSaverActiveNotifier.value) return res;
    return _LongValidityResponse(res);
  }
}

class _LongValidityResponse implements FileServiceResponse {
  _LongValidityResponse(this._inner);
  final FileServiceResponse _inner;

  @override
  Stream<List<int>> get content => _inner.content;

  @override
  int? get contentLength => _inner.contentLength;

  @override
  int get statusCode => _inner.statusCode;

  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 30));

  @override
  String? get eTag => _inner.eTag;

  @override
  String get fileExtension => _inner.fileExtension;
}
