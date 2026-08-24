package com.example.native_feed_player

import kotlin.math.abs

/**
 * A source the feed can play, addressed by a caller-owned stable id.
 */
internal data class RegisteredSource(
    val id: String,
    val uri: String,
    val rank: Int,
    val kind: FeedMediaKindMessage,
    val headers: Map<String, String>
)

/**
 * Ordered set of feed sources plus the window arithmetic over them.
 *
 * Sources are keyed by id rather than list position, so appending a page
 * cannot renumber existing entries or invalidate the preload window. Rank is
 * only an ordering hint used to compute distance from the viewport.
 */
internal class FeedSourceRegistry {
    private val sourcesById = linkedMapOf<String, RegisteredSource>()

    var visibleSourceId: String? = null
        private set

    val size: Int get() = sourcesById.size

    fun replaceAll(sources: List<RegisteredSource>) {
        sourcesById.clear()
        append(sources)
        if (visibleSourceId !in sourcesById.keys) {
            visibleSourceId = lowestRankedId()
        }
    }

    fun append(sources: List<RegisteredSource>) {
        for (source in sources) {
            if (source.uri.isBlank()) {
                continue
            }
            sourcesById[source.id] = source
        }
        if (visibleSourceId == null) {
            visibleSourceId = lowestRankedId()
        }
    }

    fun remove(ids: Collection<String>) {
        for (id in ids) {
            sourcesById.remove(id)
        }
        if (visibleSourceId !in sourcesById.keys) {
            visibleSourceId = lowestRankedId()
        }
    }

    fun clear() {
        sourcesById.clear()
        visibleSourceId = null
    }

    fun setVisible(sourceId: String) {
        if (sourcesById.containsKey(sourceId)) {
            visibleSourceId = sourceId
        }
    }

    fun source(id: String): RegisteredSource? = sourcesById[id]

    fun all(): Collection<RegisteredSource> = sourcesById.values

    fun visibleRank(): Int? = visibleSourceId?.let { sourcesById[it]?.rank }

    /** Distance in feed positions from the visible source, or null if unknown. */
    fun distanceFromVisible(id: String): Int? {
        val rank = sourcesById[id]?.rank ?: return null
        val visibleRank = visibleRank() ?: return null
        return abs(rank - visibleRank)
    }

    /**
     * Sources that should be prepared, nearest first.
     *
     * The window is asymmetric because feeds travel forward: [ahead] positions
     * past the viewport are worth more than [behind] positions already seen.
     */
    fun preloadWindow(ahead: Int, behind: Int): List<RegisteredSource> {
        val visibleRank = visibleRank() ?: return emptyList()
        return sourcesById.values
            .filter { source ->
                val delta = source.rank - visibleRank
                delta in -behind..ahead
            }
            .sortedBy { source -> abs(source.rank - visibleRank) }
    }

    private fun lowestRankedId(): String? =
        sourcesById.values.minByOrNull { it.rank }?.id
}
