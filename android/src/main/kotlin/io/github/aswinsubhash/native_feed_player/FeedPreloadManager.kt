package io.github.aswinsubhash.native_feed_player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.preload.DefaultPreloadManager
import androidx.media3.exoplayer.source.preload.TargetPreloadStatusControl
import kotlin.math.abs

/**
 * MediaSource-level preloading for nearby feed items.
 *
 * Players and preloaded sources must share the same builder.
 */
@OptIn(UnstableApi::class)
internal class FeedPreloadManager(
    context: Context,
    headerLookup: (uri: String) -> Map<String, String>
) {
    /** Selects memory or disk preloading by viewport distance. */
    private inner class DistanceBasedStatusControl :
        TargetPreloadStatusControl<Int, DefaultPreloadManager.PreloadStatus> {
        override fun getTargetPreloadStatus(rankingData: Int): DefaultPreloadManager.PreloadStatus {
            return when (val distance = abs(rankingData - currentRank)) {
                // The playing item is driven by its own player.
                0 -> DefaultPreloadManager.PreloadStatus.PRELOAD_STATUS_NOT_PRELOADED
                1 -> DefaultPreloadManager.PreloadStatus
                    .specifiedRangeLoaded(FIRST_NEIGHBOUR_PRELOAD_MS)
                else ->
                    if (distance <= maxPreloadDistance && cacheAvailable) {
                        DefaultPreloadManager.PreloadStatus
                            .specifiedRangeCached(DISTANT_PRELOAD_MS)
                    } else if (distance <= maxPreloadDistance) {
                        DefaultPreloadManager.PreloadStatus.PRELOAD_STATUS_TRACKS_SELECTED
                    } else {
                        DefaultPreloadManager.PreloadStatus.PRELOAD_STATUS_NOT_PRELOADED
                    }
            }
        }
    }

    private val cacheAvailable: Boolean = MediaCache.activeCache() != null
    private val builder: DefaultPreloadManager.Builder
    private val delegate: DefaultPreloadManager
    private val addedItemsByUri = mutableMapOf<String, MediaItem>()

    private var currentRank: Int = 0
    private var maxPreloadDistance: Int = 2

    init {
        builder = DefaultPreloadManager.Builder(
            context.applicationContext,
            DistanceBasedStatusControl()
        )
            .setDataSourceFactory(MediaCache.createDataSourceFactory(headerLookup))
            .setLoadControl(
                DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        /* minBufferMs = */ 2_000,
                        /* maxBufferMs = */ 10_000,
                        /* bufferForPlaybackMs = */ 1_000,
                        /* bufferForPlaybackAfterRebufferMs = */ 2_000
                    )
                    .build()
            )

        MediaCache.activeCache()?.let { builder.setCache(it) }
        delegate = builder.build()
    }

    /** Players must come from the preload manager's builder to reuse sources. */
    fun buildPlayer(): ExoPlayer = builder.buildExoPlayer()

    fun setMaxPreloadDistance(distance: Int) {
        maxPreloadDistance = distance.coerceAtLeast(1)
    }

    /** Synchronizes the nearest unique sources with the preload window. */
    fun sync(window: List<RegisteredSource>, visibleRank: Int) {
        currentRank = visibleRank

        val wanted = window.associateBy { it.uri }
        for ((uri, item) in addedItemsByUri.toList()) {
            if (!wanted.containsKey(uri)) {
                delegate.remove(item)
                addedItemsByUri.remove(uri)
            }
        }

        for (source in window) {
            if (addedItemsByUri.containsKey(source.uri)) {
                continue
            }
            val item = MediaItem.fromUri(source.uri)
            delegate.add(item, source.rank)
            addedItemsByUri[source.uri] = item
        }

        delegate.setCurrentPlayingIndex(visibleRank)
        delegate.invalidate()
    }

    /** Returns the preloaded source for [source], if available. */
    fun mediaSourceFor(source: RegisteredSource): MediaSource? {
        val item = addedItemsByUri[source.uri] ?: return null
        return delegate.getMediaSource(item)
    }

    fun reset() {
        delegate.reset()
        addedItemsByUri.clear()
    }

    /** Releases shared preload components. */
    fun release() {
        delegate.release()
        addedItemsByUri.clear()
    }

    private companion object {
        const val FIRST_NEIGHBOUR_PRELOAD_MS = 3_000L
        const val DISTANT_PRELOAD_MS = 2_000L
    }
}
