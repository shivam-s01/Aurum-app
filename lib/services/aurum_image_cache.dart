import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// AurumImageCache — disk cache for network artwork.
///
/// ZERO-MB COLD START: by default flutter_cache_manager honours the
/// server's Cache-Control max-age (YouTube/Saavn CDNs often send short
/// values), so once an entry "expires" the next cold start re-requests it
/// (conditional GET / full re-download) even though the artwork never
/// changed. [_LongCacheFileService] forces every response to be treated as
/// valid for 30 days, so a cached thumbnail is served from disk with NO
/// network request on every cold start until it is evicted.
class AurumImageCache extends CacheManager {
  static const key = 'aurumImageCache';
  static final AurumImageCache _instance = AurumImageCache._();
  factory AurumImageCache() => _instance;

  AurumImageCache._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 30),
            maxNrOfCacheObjects: 4000,
            fileService: _LongCacheFileService(),
          ),
        );
}

class _LongCacheFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final res = await super.get(url, headers: headers);
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
