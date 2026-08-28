package io.github.aswinsubhash.native_feed_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class FeedSourceRegistryTest {
    private fun source(id: String, rank: Int) = RegisteredSource(
        id = id,
        uri = "https://example.test/$id.mp4",
        rank = rank,
        kind = FeedMediaKindMessage.AUTO,
        headers = emptyMap()
    )

    private fun registry(count: Int, visible: String? = null): FeedSourceRegistry {
        val registry = FeedSourceRegistry()
        registry.replaceAll((0 until count).map { source("s$it", it) })
        if (visible != null) {
            registry.setVisible(visible)
        }
        return registry
    }

    @Test
    fun replaceAll_defaultsVisibleToLowestRank() {
        val registry = registry(3)
        assertEquals("s0", registry.visibleSourceId)
    }

    @Test
    fun append_preservesExistingRanks() {
        val registry = registry(2, visible = "s1")
        registry.append(listOf(source("page2", 2), source("page3", 3)))

        assertEquals("s1", registry.visibleSourceId)
        assertEquals(1, registry.visibleRank())
        assertEquals(4, registry.size)
        assertEquals(2, registry.source("page2")?.rank)
    }

    @Test
    fun window_isBiasedForward() {
        val registry = registry(10, visible = "s5")

        val ids = registry.preloadWindow(ahead = 2, behind = 1).map { it.id }

        assertEquals(listOf("s5", "s4", "s6", "s7"), ids)
    }

    @Test
    fun direction_isInferredFromSuccessiveViewportUpdates() {
        val registry = registry(5)
        assertEquals(ScrollDirection.UNKNOWN, registry.direction)

        registry.setVisible("s1")
        assertEquals(ScrollDirection.FORWARD, registry.direction)

        registry.setVisible("s0")
        assertEquals(ScrollDirection.BACKWARD, registry.direction)
    }

    @Test
    fun direction_isUnchangedWhenReselectingTheSamePosition() {
        val registry = registry(5)
        registry.setVisible("s2")
        assertEquals(ScrollDirection.FORWARD, registry.direction)

        registry.setVisible("s2")
        assertEquals(ScrollDirection.FORWARD, registry.direction)
    }

    @Test
    fun window_followsTravelWhenScrollingBackwards() {
        val registry = registry(10)
        registry.setVisible("s5")
        registry.setVisible("s4")

        val ids = registry.preloadWindow(ahead = 2, behind = 1).map { it.id }

        assertEquals(listOf("s4", "s3", "s5", "s2"), ids)
    }

    @Test
    fun window_collapsesDuplicateUris() {
        val registry = FeedSourceRegistry()
        val repeated = "https://example.test/repeat.mp4"
        registry.replaceAll(
            listOf(
                source("a", 0),
                RegisteredSource("b", repeated, 1, FeedMediaKindMessage.AUTO, emptyMap()),
                RegisteredSource("c", repeated, 2, FeedMediaKindMessage.AUTO, emptyMap())
            )
        )
        registry.setVisible("a")

        val ids = registry.preloadWindow(ahead = 3, behind = 0).map { it.id }

        assertEquals(listOf("a", "b"), ids)
    }

    @Test
    fun window_shrinksWithScale() {
        val registry = registry(10, visible = "s5")

        val full = registry.preloadWindow(ahead = 4, behind = 2, scale = 1.0)
        val halved = registry.preloadWindow(ahead = 4, behind = 2, scale = 0.5)

        assertTrue(halved.size < full.size)
        assertEquals("s5", halved.first().id)
    }

    @Test
    fun window_atMinimumScaleStillIncludesVisibleSource() {
        val registry = registry(10, visible = "s5")

        val ids = registry.preloadWindow(ahead = 2, behind = 1, scale = 0.25).map { it.id }

        assertTrue(ids.contains("s5"))
    }

    @Test
    fun window_clampsAtFeedBounds() {
        val registry = registry(3, visible = "s0")

        val ids = registry.preloadWindow(ahead = 5, behind = 5).map { it.id }

        assertEquals(listOf("s0", "s1", "s2"), ids)
    }

    @Test
    fun window_isEmptyWithoutSources() {
        val registry = FeedSourceRegistry()
        assertTrue(registry.preloadWindow(ahead = 2, behind = 1).isEmpty())
        assertNull(registry.visibleRank())
    }

    @Test
    fun distanceFromVisible_usesRankNotInsertionOrder() {
        val registry = FeedSourceRegistry()
        // Deliberately inserted out of order.
        registry.replaceAll(
            listOf(source("c", 2), source("a", 0), source("b", 1))
        )
        registry.setVisible("a")

        assertEquals(0, registry.distanceFromVisible("a"))
        assertEquals(1, registry.distanceFromVisible("b"))
        assertEquals(2, registry.distanceFromVisible("c"))
        assertNull(registry.distanceFromVisible("missing"))
    }

    @Test
    fun remove_movesVisibleToLowestRemainingRank() {
        val registry = registry(3, visible = "s1")
        registry.remove(listOf("s1"))

        assertEquals("s0", registry.visibleSourceId)
        assertEquals(2, registry.size)
    }

    @Test
    fun setVisible_ignoresUnknownSource() {
        val registry = registry(2, visible = "s1")
        registry.setVisible("does-not-exist")

        assertEquals("s1", registry.visibleSourceId)
    }

    @Test
    fun blankUriSourcesAreSkipped() {
        val registry = FeedSourceRegistry()
        registry.replaceAll(
            listOf(
                source("ok", 0),
                RegisteredSource(
                    id = "blank",
                    uri = "",
                    rank = 1,
                    kind = FeedMediaKindMessage.AUTO,
                    headers = emptyMap()
                )
            )
        )

        assertEquals(1, registry.size)
        assertNull(registry.source("blank"))
    }
}
