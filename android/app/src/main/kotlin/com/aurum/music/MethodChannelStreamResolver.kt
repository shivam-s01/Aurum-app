package com.aurum.music

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Calls back into Dart's ApiService.resolveStreamUrl via MethodChannel.
 * suspendCancellableCoroutine + invokeMethod's cancel: when the coroutine
 * Job backing this call is cancelled (superseded session, I7), the
 * continuation is dropped and Dart-side is told to abandon the resolve via
 * a matching "cancelResolve" call keyed by requestId — true cancellation,
 * not just an ignored result.
 */
class MethodChannelStreamResolver(messenger: BinaryMessenger) : StreamResolver {

    private val channel = MethodChannel(messenger, "com.aurum.music/stream_resolver")
    private var nextRequestId = 0

    override suspend fun resolve(song: NativeSong, forceRefresh: Boolean): String? =
        suspendCancellableCoroutine { cont ->
            val requestId = nextRequestId++
            val args = mapOf(
                "requestId" to requestId,
                "songId" to song.id,
                "title" to song.title,
                "artist" to song.artist,
                "source" to song.source,
                "isLocal" to song.isLocal,
                "localPath" to song.localPath,
                "forceRefresh" to forceRefresh,
            )
            channel.invokeMethod("resolveStreamUrl", args, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (cont.isActive) cont.resume(result as? String)
                }
                override fun error(code: String, message: String?, details: Any?) {
                    if (cont.isActive) cont.resume(null)
                }
                override fun notImplemented() {
                    if (cont.isActive) cont.resume(null)
                }
            })
            cont.invokeOnCancellation {
                // I7: tell Dart to actually abandon this in-flight resolve
                // (cancel the underlying http.Client request) instead of
                // just discarding the result here.
                channel.invokeMethod("cancelResolve", mapOf("requestId" to requestId))
            }
        }

    override suspend fun invalidate(song: NativeSong) {
        channel.invokeMethod("invalidateStream", mapOf("songId" to song.id, "source" to song.source))
    }
}
