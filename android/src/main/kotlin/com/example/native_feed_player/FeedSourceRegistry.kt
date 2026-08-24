package com.example.native_feed_player

import kotlin.math.abs
import kotlin.math.max

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

/** Which way the viewport is travelling through the feed. */
internal enum class ScrollDirection { UNKNOWN, FORWARD, BACKWARD }

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

    /**
     * Inferred from successive viewport updates. Feeds are overwhelmingly
     * consumed in one direction, so the preload budget should follow travel
     * rather than spend half of itself behind the user.
     */
    var direction: ScrollDirection = ScrollDirection.UNKNOWN
        private set

    val size: Int get() = sourcesById.size

    fun replaceAll(sources: List<RegisteredSource>) {
        sourcesById.clear()
        direction = ScrollDirection.UNKNOWN
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
            direction = ScrollDirection.UNKNOWN
        }
    }

    fun clear() {
        sourcesById.clear()
        visibleSourceId = null
        direction = ScrollDirection.UNKNOWN
    }

    fun setVisible(sourceId: String) {
        val target = sourcesById[sourceId] ?: return
        val previousRank = visibleRank()
        visibleSourceId = sourceId
        direction = when {
            previousRank == null -> ScrollDirection.UNKNOWN
            target.rank > previousRank -> ScrollDirection.FORWARD
            target.rank < previousRank -> ScrollDirection.BACKWARD
            // Re-selecting the same position tells us nothing new.
            else -> direction
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
     * [ahead] and [behind] are expressed relative to travel, not to rank: when
     * the user scrolls backwards they are swapped so the budget still lands in
     * front of the viewport.
     *
     * [scale] shrinks the window under sustained stress; 1.0 is the configured
     * size. Sources sharing a URI are collapsed to the nearest one so a feed
     * that repeats a clip does not prepare it twice.
     */
    fun preloadWindow(ahead: Int, behind: Int, scale: Double = 1.0): List<RegisteredSource> {
        val visibleRank = visibleRank() ?: return emptyList()

        val forwardBudget = if (direction == ScrollDirection.BACKWARD) behind else ahead
        val backwardBudget = if (direction == ScrollDirection.BACKWARD) ahead else behind
        val scaledForward = scaleBudget(forwardBudget, scale)
        val scaledBackward = scaleBudget(backwardBudget, scale)

        val seenUris = mutableSetOf<String>()
        return sourcesById.values
            .filter { source ->
                val delta = source.rank - visibleRank
                delta in -scaledBackward..scaledForward
            }
            .sortedBy { source -> abs(source.rank - visibleRank) }
            .filter { source -> seenUris.add(source.uri) }
    }

    /** Keeps at least the visible item in the window while scaling down. */
    private fun scaleBudget(budget: Int, scale: Double): Int {
        if (budget <= 0) {
            return 0
        }
        return max(0, Math.round(budget * scale).toInt())
    }

    private fun lowestRankedId(): String? =
        sourcesById.values.minByOrNull { it.rank }?.id
}
