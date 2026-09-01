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
    context: Context
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
    private val addedItemsByIdentity = mutableMapOf<String, MediaItem>()

    private var currentRank: Int = 0
    private var maxPreloadDistance: Int = 2

    init {
        builder = DefaultPreloadManager.Builder(
            context.applicationContext,
            DistanceBasedStatusControl()
        )
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

        val wanted = window.associateBy { it.cacheIdentity }
        for ((identity, item) in addedItemsByIdentity.toList()) {
            if (!wanted.containsKey(identity)) {
                delegate.remove(item)
                addedItemsByIdentity.remove(identity)
            }
        }

        for (source in window) {
            val identity = source.cacheIdentity
            if (addedItemsByIdentity.containsKey(identity)) {
                continue
            }
            val mediaSource = MediaCache.createMediaSource(source)
            val item = mediaSource.mediaItem
            delegate.add(mediaSource, source.rank)
            addedItemsByIdentity[identity] = item
        }

        delegate.setCurrentPlayingIndex(visibleRank)
        delegate.invalidate()
    }

    /** Returns the preloaded source for [source], if available. */
    fun mediaSourceFor(source: RegisteredSource): MediaSource? {
        val item = addedItemsByIdentity[source.cacheIdentity] ?: return null
        return delegate.getMediaSource(item)
    }

    fun reset() {
        delegate.reset()
        addedItemsByIdentity.clear()
    }

    fun sourceCount(): Int = addedItemsByIdentity.size

    /** Releases shared preload components. */
    fun release() {
        delegate.release()
        addedItemsByIdentity.clear()
    }

    private companion object {
        const val FIRST_NEIGHBOUR_PRELOAD_MS = 3_000L
        const val DISTANT_PRELOAD_MS = 2_000L
    }
}
