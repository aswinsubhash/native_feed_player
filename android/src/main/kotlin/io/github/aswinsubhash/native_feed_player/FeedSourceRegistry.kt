package io.github.aswinsubhash.native_feed_player

import java.util.TreeMap
import kotlin.math.abs
import kotlin.math.max

/** A feed source with a caller-defined stable ID. */
internal data class RegisteredSource(
    val id: String,
    val uri: String,
    val rank: Int,
    val kind: FeedMediaKindMessage,
    val headers: Map<String, String>,
    /** Optional stable cache identity replacing [uri] in cache keys. */
    val cacheKey: String? = null
)

/** Viewport travel direction. */
internal enum class ScrollDirection { UNKNOWN, FORWARD, BACKWARD }

/** Ordered sources keyed by stable ID with preload-window operations. */
internal class FeedSourceRegistry {
    private val sourcesById = linkedMapOf<String, RegisteredSource>()
    private val sourceIdsByRank = TreeMap<Int, MutableSet<String>>()
    private val insertionOrder = mutableMapOf<String, Long>()
    private var nextInsertionOrder = 0L

    var visibleSourceId: String? = null
        private set

    /** Inferred direction used to bias the preload window. */
    var direction: ScrollDirection = ScrollDirection.UNKNOWN
        private set

    val size: Int get() = sourcesById.size

    fun replaceAll(sources: List<RegisteredSource>) {
        sourcesById.clear()
        sourceIdsByRank.clear()
        insertionOrder.clear()
        nextInsertionOrder = 0L
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
            sourcesById[source.id]?.let(::removeFromRankIndex)
            if (source.id !in insertionOrder) {
                insertionOrder[source.id] = nextInsertionOrder++
            }
            sourcesById[source.id] = source
            sourceIdsByRank.getOrPut(source.rank) { linkedSetOf() }.add(source.id)
        }
        if (visibleSourceId == null) {
            visibleSourceId = lowestRankedId()
        }
    }

    fun remove(ids: Collection<String>) {
        for (id in ids) {
            sourcesById.remove(id)?.let(::removeFromRankIndex)
            insertionOrder.remove(id)
        }
        if (visibleSourceId !in sourcesById.keys) {
            visibleSourceId = lowestRankedId()
            direction = ScrollDirection.UNKNOWN
        }
    }

    fun clear() {
        sourcesById.clear()
        sourceIdsByRank.clear()
        insertionOrder.clear()
        nextInsertionOrder = 0L
        visibleSourceId = null
        direction = ScrollDirection.UNKNOWN
    }

    fun setVisible(sourceId: String): Boolean {
        val target = sourcesById[sourceId] ?: return false
        val previousRank = visibleRank()
        visibleSourceId = sourceId
        direction = when {
            previousRank == null -> ScrollDirection.UNKNOWN
            target.rank > previousRank -> ScrollDirection.FORWARD
            target.rank < previousRank -> ScrollDirection.BACKWARD
            // Preserve direction when the rank is unchanged.
            else -> direction
        }
        return true
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
     * Returns the nearest unique sources in the travel-relative preload window.
     * [scale] applies runtime window degradation.
     */
    fun preloadWindow(ahead: Int, behind: Int, scale: Double = 1.0): List<RegisteredSource> {
        val visibleRank = visibleRank() ?: return emptyList()

        val forwardBudget = if (direction == ScrollDirection.BACKWARD) behind else ahead
        val backwardBudget = if (direction == ScrollDirection.BACKWARD) ahead else behind
        val scaledForward = scaleBudget(forwardBudget, scale)
        val scaledBackward = scaleBudget(backwardBudget, scale)

        val lowerRank = (visibleRank.toLong() - scaledBackward).coerceAtLeast(Int.MIN_VALUE.toLong()).toInt()
        val upperRank = (visibleRank.toLong() + scaledForward).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        val seenIdentities = mutableSetOf<String>()
        return sourceIdsByRank.subMap(lowerRank, true, upperRank, true).values
            .asSequence()
            .flatMap { it.asSequence() }
            .mapNotNull { sourcesById[it] }
            .sortedWith(compareBy<RegisteredSource>(
                { abs(it.rank.toLong() - visibleRank) },
                { insertionOrder.getValue(it.id) }
            ))
            .filter { source -> seenIdentities.add(source.requestIdentity) }
            .toList()
    }

    /** Scales a preload budget without excluding the visible source. */
    private fun scaleBudget(budget: Int, scale: Double): Int {
        if (budget <= 0) {
            return 0
        }
        return max(0, Math.round(budget * scale).toInt())
    }

    fun isOrphaned(
        sourceId: String,
        sourceIdentity: String,
        sourceKind: FeedMediaKindMessage
    ): Boolean {
        val source = sourcesById[sourceId] ?: return true
        return source.requestIdentity != sourceIdentity || source.kind != sourceKind
    }

    private fun removeFromRankIndex(source: RegisteredSource) {
        val ids = sourceIdsByRank[source.rank] ?: return
        ids.remove(source.id)
        if (ids.isEmpty()) {
            sourceIdsByRank.remove(source.rank)
        }
    }

    private fun lowestRankedId(): String? =
        sourceIdsByRank.firstEntry()?.value?.minByOrNull { insertionOrder.getValue(it) }
}
