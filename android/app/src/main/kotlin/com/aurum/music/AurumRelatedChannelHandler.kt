package com.aurum.music

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Dedicated, self-contained channel exposing YoutubeInnertube.getRelated()
 * to Dart — YouTube's own "related videos" / "Up Next" graph for a given
 * video ID, used as an additional signal in getAutoQueue alongside Saavn's
 * similar-songs search (see api_service.dart's getAutoQueue doc comment).
 *
 * Kept as its own small file + own channel (rather than adding a case to
 * AurumEngineChannelHandler's playback-command switch, or a case to
 * MainActivity's existing "com.aurum.music/media_store" channel) so this
 * addition can't interfere with either of those — a network-bound related-
 * videos fetch has nothing to do with playback commands or media-store
 * queries, and giving it a dedicated channel means a failure or slow
 * response here can never block/queue behind unrelated calls on a channel
 * that also carries time-sensitive playback commands.
 */
class AurumRelatedChannelHandler(messenger: BinaryMessenger) {

    companion object {
        private const val CHANNEL = "com.aurum.music/related_videos"
    }

    private val scope = CoroutineScope(Dispatchers.Main.immediate)
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getRelated" -> {
                    val videoId = call.argument<String>("videoId")
                    if (videoId.isNullOrBlank()) {
                        result.success(emptyList<Map<String, Any?>>())
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        val related = try {
                            YoutubeInnertube.getRelated(videoId)
                        } catch (e: Exception) {
                            // getRelated() already catches internally and
                            // returns emptyList() on failure — this outer
                            // catch is just a last-resort guard so a
                            // MethodChannel result is always sent, even if
                            // something unexpected throws past that.
                            emptyList()
                        }
                        result.success(
                            related.map {
                                mapOf(
                                    "videoId" to it.videoId,
                                    "title" to it.title,
                                    "uploaderName" to it.uploaderName,
                                    "durationSecs" to it.durationSecs,
                                    "viewCount" to it.viewCount,
                                )
                            },
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
