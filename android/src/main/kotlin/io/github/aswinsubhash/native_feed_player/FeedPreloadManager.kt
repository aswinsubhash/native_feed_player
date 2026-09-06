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
import java.util.concurrent.ConcurrentHashMap
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
            val rank = registeredRanks[rankingData]
                ?: return DefaultPreloadManager.PreloadStatus.PRELOAD_STATUS_NOT_PRELOADED
            return when (val distance = abs(rank.toLong() - currentRank)) {
                // The playing item is driven by its own player.
                0L -> DefaultPreloadManager.PreloadStatus.PRELOAD_STATUS_NOT_PRELOADED
                1L -> DefaultPreloadManager.PreloadStatus
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
    private data class Registration(val item: MediaItem, val rankingToken: Int)

    private val addedItemsByIdentity = mutableMapOf<String, Registration>()
    private val registeredRanks = ConcurrentHashMap<Int, Int>()
    private var nextRankingToken = 0
    private val rankingComparator = object : DefaultPreloadManager.SimpleRankingDataComparator() {
        override fun compare(first: Int, second: Int): Int {
            val firstDistance = registeredRanks[first]?.let { abs(it.toLong() - currentRank) } ?: Long.MAX_VALUE
            val secondDistance = registeredRanks[second]?.let { abs(it.toLong() - currentRank) } ?: Long.MAX_VALUE
            return firstDistance.compareTo(secondDistance)
        }
    }

    /** Sources that failed to build while they remain in the current preload window. */
    private val failedIdentities = mutableSetOf<String>()

    /** Notifies the owner when a source cannot be turned into a MediaSource. */
    var onSourceFailed: ((RegisteredSource, Throwable) -> Unit)? = null

    private var currentRank: Int = 0
    private var maxPreloadDistance: Int = 2

    init {
        builder = DefaultPreloadManager.Builder(
            context.applicationContext,
            rankingComparator,
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

        val wanted = window.associateBy { it.requestIdentity }
        failedIdentities.retainAll(wanted.keys)
        for ((identity, registration) in addedItemsByIdentity.toList()) {
            if (!wanted.containsKey(identity)) {
                delegate.remove(registration.item)
                registeredRanks.remove(registration.rankingToken)
                addedItemsByIdentity.remove(identity)
            }
        }

        for (source in window) {
            val identity = source.requestIdentity
            val retained = addedItemsByIdentity[identity]
            if (retained != null) {
                if (registeredRanks[retained.rankingToken] != source.rank) {
                    registeredRanks[retained.rankingToken] = source.rank
                }
                continue
            }
            if (identity in failedIdentities) {
                continue
            }
            // A malformed or unsupported source must not crash the looper
            // callback; skip it and let the caller surface the failure.
            val mediaSource = try {
                MediaCache.createMediaSource(source)
            } catch (error: Throwable) {
                failedIdentities.add(identity)
                onSourceFailed?.invoke(source, error)
                continue
            }
            val item = mediaSource.mediaItem
            val token = nextRankingToken++
            registeredRanks[token] = source.rank
            delegate.add(mediaSource, token)
            addedItemsByIdentity[identity] = Registration(item, token)
        }

        delegate.setCurrentPlayingIndex(visibleRank)
        delegate.invalidate()
    }

    /** Returns the preloaded source for [source], if available. */
    fun mediaSourceFor(source: RegisteredSource): MediaSource? {
        val registration = addedItemsByIdentity[source.requestIdentity] ?: return null
        return delegate.getMediaSource(registration.item)
    }

    fun reset() {
        delegate.reset()
        addedItemsByIdentity.clear()
        registeredRanks.clear()
        failedIdentities.clear()
    }

    fun sourceCount(): Int = addedItemsByIdentity.size

    /** Releases shared preload components. */
    fun release() {
        delegate.release()
        addedItemsByIdentity.clear()
        registeredRanks.clear()
    }

    private companion object {
        const val FIRST_NEIGHBOUR_PRELOAD_MS = 3_000L
        const val DISTANT_PRELOAD_MS = 2_000L
    }
}
