package com.example.native_feed_player

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
 * Wraps Media3's [DefaultPreloadManager].
 *
 * The previous approach kept a fully built ExoPlayer alive for every upcoming
 * item, which is by far the most expensive way to preload. The preload manager
 * works at the MediaSource level instead, so nearby items cost a prepared
 * source rather than a whole player.
 *
 * Players must be built from the same builder so they share the load control,
 * bandwidth meter, track selector, and playback looper; a preloaded source is
 * only valid on a player from that builder.
 */
@OptIn(UnstableApi::class)
internal class FeedPreloadManager(
    context: Context,
    headerLookup: (uri: String) -> Map<String, String>
) {
    /**
     * How much of an item to preload, by distance from the viewport.
     *
     * The immediate neighbour is buffered into memory so promotion is instant.
     * Anything further out is only cached to disk: it costs no heap, and when
     * the user reaches it the bytes are already local.
     */
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

    /**
     * Syncs the manager with the current window.
     *
     * Ranks come from the registry, so a repeated URI resolves to one entry and
     * pagination never renumbers what is already added.
     */
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

    /**
     * Returns a preloaded source when one exists, so playback starts from
     * already-buffered media instead of re-preparing from scratch.
     */
    fun mediaSourceFor(source: RegisteredSource): MediaSource? {
        val item = addedItemsByUri[source.uri] ?: return null
        return delegate.getMediaSource(item)
    }

    fun reset() {
        delegate.reset()
        addedItemsByUri.clear()
    }

    /**
     * Must be released before the players built from it, because they share
     * components.
     */
    fun release() {
        delegate.release()
        addedItemsByUri.clear()
    }

    private companion object {
        const val FIRST_NEIGHBOUR_PRELOAD_MS = 3_000L
        const val DISTANT_PRELOAD_MS = 2_000L
    }
}
