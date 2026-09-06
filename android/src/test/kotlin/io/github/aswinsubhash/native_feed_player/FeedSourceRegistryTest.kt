package io.github.aswinsubhash.native_feed_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
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
        assertFalse(registry.setVisible("does-not-exist"))

        assertEquals("s1", registry.visibleSourceId)
        assertTrue(registry.setVisible("s0"))
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

    @Test
    fun cacheIdentity_isStableAcrossHeaderOrderAndNameCase_withoutLeakingSecrets() {
        val uri = "https://example.test/video.m3u8?token=query-secret"
        val first = CacheIdentity.forSource(
            uri,
            linkedMapOf("Authorization" to "Bearer super-secret", "X-Tenant" to "42")
        )
        val reordered = CacheIdentity.forSource(
            uri,
            linkedMapOf("x-tenant" to "42", "authorization" to "Bearer super-secret")
        )

        assertEquals(first, reordered)
        assertTrue(first.startsWith(CacheIdentity.CACHE_KEY_PREFIX))
        assertFalse(first.contains("super-secret"))
        assertFalse(first.contains("query-secret"))
        val childKey = CacheIdentity.cacheKey(first, "https://cdn.test/segment.ts?sig=child-secret")
        assertTrue(childKey.startsWith("$first/"))
        assertFalse(childKey.contains("child-secret"))
    }

    @Test
    fun cacheIdentity_changesWithUriOrCredentials() {
        val base = CacheIdentity.forSource(
            "https://example.test/video.mp4",
            mapOf("Authorization" to "Bearer one")
        )

        assertNotEquals(
            base,
            CacheIdentity.forSource(
                "https://example.test/video.mp4",
                mapOf("Authorization" to "Bearer two")
            )
        )
        assertNotEquals(
            base,
            CacheIdentity.forSource(
                "https://example.test/other.mp4",
                mapOf("Authorization" to "Bearer one")
            )
        )
    }

    @Test
    fun preloadWindow_keepsSameUriWhenCredentialsDiffer() {
        val registry = FeedSourceRegistry()
        val uri = "https://example.test/private.m3u8"
        registry.replaceAll(
            listOf(
                RegisteredSource("a", uri, 0, FeedMediaKindMessage.HLS, mapOf("Token" to "a")),
                RegisteredSource("b", uri, 1, FeedMediaKindMessage.HLS, mapOf("Token" to "b"))
            )
        )

        assertEquals(listOf("a", "b"), registry.preloadWindow(2, 0).map { it.id })
    }

    @Test
    fun replaceAll_marksRemovedOrIdentityChangedControllerSourcesAsOrphans() {
        val registry = FeedSourceRegistry()
        val original = RegisteredSource(
            "same-id",
            "https://example.test/video.mp4",
            0,
            FeedMediaKindMessage.PROGRESSIVE,
            mapOf("Authorization" to "old")
        )
        registry.replaceAll(listOf(original))
        val identity = original.requestIdentity
        assertFalse(registry.isOrphaned(original.id, identity, original.kind))

        registry.replaceAll(listOf(original.copy(headers = mapOf("Authorization" to "new"))))
        assertTrue(registry.isOrphaned(original.id, identity, original.kind))
        assertTrue(registry.isOrphaned("removed-id", identity, original.kind))
    }

    @Test
    fun requestIdentity_tracksSourceMetadataButNotRank() {
        val original = source("a", 0).copy(
            uri = "https://cdn.test/video.mp4?sig=old",
            headers = mapOf("Authorization" to "Bearer one"),
            cacheKey = "stable"
        )
        val registry = FeedSourceRegistry()
        val rotated = original.copy(uri = "https://cdn.test/video.mp4?sig=new")
        assertEquals(original.cacheIdentity, rotated.cacheIdentity)
        for (replacement in listOf(
            rotated,
            original.copy(kind = FeedMediaKindMessage.HLS),
            original.copy(headers = mapOf("Authorization" to "Bearer two")),
            original.copy(cacheKey = "other"),
            original.copy(cacheKey = null)
        )) {
            registry.replaceAll(listOf(replacement))
            assertTrue(registry.isOrphaned(original.id, original.requestIdentity, original.kind))
        }
        val respelled = original.copy(headers = mapOf(" authorization " to " Bearer one "))
        assertEquals(original.cacheIdentity, respelled.cacheIdentity)
        assertNotEquals(original.requestIdentity, respelled.requestIdentity)
        val equivalent = original.copy(rank = 100)
        registry.replaceAll(listOf(equivalent))
        assertEquals(original.requestIdentity, equivalent.requestIdentity)
        assertFalse(registry.isOrphaned(original.id, original.requestIdentity, original.kind))
        assertNotEquals(original.copy(cacheKey = null).requestIdentity, original.copy(cacheKey = "").requestIdentity)
    }

    @Test
    fun preloadWindow_deduplicatesRequestsInsteadOfStableDiskIdentities() {
        val original = source("a", 0).copy(cacheKey = "stable")
        val registry = FeedSourceRegistry()
        registry.replaceAll(listOf(
            original,
            original.copy(id = "duplicate", rank = 1),
            original.copy(id = "rotated", rank = 2, uri = "${original.uri}?sig=new"),
            original.copy(id = "kind", rank = 3, kind = FeedMediaKindMessage.HLS),
            original.copy(id = "key", rank = 4, cacheKey = "different")
        ))
        assertEquals(listOf("a", "rotated", "kind", "key"), registry.preloadWindow(4, 0).map { it.id })
    }

    @Test
    fun indexedWindow_preservesInsertionTiesAndRankUpdates() {
        val registry = FeedSourceRegistry()
        registry.replaceAll(listOf(
            source("right", 101), source("left", 99), source("visible", 100),
            source("same", 100), source("far", -1000)
        ))
        registry.setVisible("visible")
        assertEquals(listOf("visible", "same", "right", "left"), registry.preloadWindow(1, 1).map { it.id })
        registry.append(listOf(source("right", 100), source("far", 102)))
        assertEquals(listOf("right", "visible", "same", "left", "far"), registry.preloadWindow(2, 1).map { it.id })
        registry.remove(listOf("right", "same", "far"))
        assertEquals(listOf("visible", "left"), registry.preloadWindow(2, 1).map { it.id })
        registry.clear()
        registry.append(listOf(source("new", -5)))
        assertEquals(listOf("new"), registry.preloadWindow(2, 1).map { it.id })
    }

    @Test
    fun indexedWindow_handlesSparseAndExtremeRanksWithoutOverflow() {
        val registry = FeedSourceRegistry()
        registry.replaceAll(listOf(
            source("min", Int.MIN_VALUE), source("max", Int.MAX_VALUE),
            source("neighbor", Int.MAX_VALUE - 1), source("middle", 0)
        ))
        registry.setVisible("max")
        assertEquals(listOf("max", "neighbor"), registry.preloadWindow(2, 2).map { it.id })
        registry.setVisible("min")
        assertEquals(listOf("min"), registry.preloadWindow(2, 2).map { it.id })
    }

    @Test
    fun indexedWindow_matchesStableScanAcrossLargeFeedAndTravelDirections() {
        val registry = FeedSourceRegistry()
        val random = kotlin.random.Random(42)
        val sources = (0 until 10_000).map { index -> source("s$index", random.nextInt(-5000, 5000)) }
        registry.replaceAll(sources)
        repeat(30) { index ->
            registry.setVisible("s${index * 300}")
            val rank = registry.visibleRank()!!
            val forward = if (registry.direction == ScrollDirection.BACKWARD) 2 else 5
            val backward = if (registry.direction == ScrollDirection.BACKWARD) 5 else 2
            val expected = sources.filter { it.rank - rank in -backward..forward }
                .sortedBy { kotlin.math.abs(it.rank - rank) }
                .distinctBy { it.requestIdentity }
            assertEquals(expected, registry.preloadWindow(5, 2))
        }
    }

    @Test
    fun sourceHeaders_overrideRequestHeadersCaseInsensitively_forChildRequests() {
        val merged = MediaCache.mergeRequestHeaders(
            requestHeaders = mapOf("authorization" to "stale", "Range" to "bytes=0-10"),
            sourceHeaders = mapOf("Authorization" to "Bearer current", "X-Tenant" to "42")
        )

        assertEquals("Bearer current", merged["authorization"])
        assertEquals("bytes=0-10", merged["range"])
        assertEquals("42", merged["x-tenant"])
        assertEquals(3, merged.size)
    }
}
