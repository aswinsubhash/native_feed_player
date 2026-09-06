package io.github.aswinsubhash.native_feed_player

import android.app.Application
import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Looper
import android.view.TextureView
import androidx.test.core.app.ApplicationProvider
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.source.preload.BasePreloadManager
import androidx.media3.exoplayer.source.preload.DefaultPreloadManager
import androidx.media3.exoplayer.source.preload.TargetPreloadStatusControl
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Guards the crash-class preload path: a source the bundled Media3 modules
 * cannot build (DASH without the dash module) must be skipped with a failure
 * callback instead of throwing from the main-looper callback.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
internal class ExoPlayerManagerPreloadResilienceTest {
    private val managers = mutableListOf<ExoPlayerManager>()

    private fun config(
        maxActivePlayers: Int = 3,
        preloadAhead: Int = 2,
        preloadBehind: Int = 1
    ) = FeedPlayerConfigMessage(
        maxActivePlayers = maxActivePlayers.toLong(),
        preloadAhead = preloadAhead.toLong(),
        preloadBehind = preloadBehind.toLong(),
        maxConcurrentPreloads = 2,
        positionUpdateIntervalMs = 200,
        renderMode = RenderModeMessage.PLATFORM_VIEW,
        cache = CachePolicyMessage(enabled = false, maxBytes = 0),
        audio = AudioPolicyMessage(
            muted = true,
            volume = 1.0,
            handleAudioFocus = false,
            manageAudioSession = true
        )
    )

    private fun manager(): ExoPlayerManager {
        val context = ApplicationProvider.getApplicationContext<Application>()
        return ExoPlayerManager(
            context = context,
            onState = { _, _, _ -> },
            onReleased = { _, _ -> },
            onPosition = { _ -> },
            onMetrics = { _ -> },
            onVideoSize = { _ -> }
        ).also(managers::add)
    }

    private fun source(id: String, rank: Int, uri: String) = RegisteredSource(
        id = id,
        uri = uri,
        rank = rank,
        kind = FeedMediaKindMessage.PROGRESSIVE,
        headers = emptyMap()
    )

    @After
    fun tearDown() {
        for (manager in managers) {
            manager.disposeAll()
        }
        managers.clear()
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test
    fun preloadWindow_withUnsupportedSource_skipsItAndKeepsScheduling() {
        val manager = manager()
        manager.initialize(config())
        manager.setSources(
            listOf(
                source("dash", 0, "https://example.test/video.mpd"),
                source("ok", 1, "https://example.test/video.mp4")
            )
        )
        manager.setVisibleSource("dash")

        // Runs the posted preload-window sync; must not throw.
        shadowOf(Looper.getMainLooper()).idle()

        // The unsupported source is skipped; the playable neighbour is kept.
        assertEquals(1, manager.scheduledPreloadCount())
    }

    @Test
    fun failedPreloadIdentity_isSuppressedUntilItLeavesWindow() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val preloadManager = FeedPreloadManager(context)
        val unsupported = source("dash", 0, "https://example.test/video.mpd")
        var failureCount = 0
        preloadManager.onSourceFailed = { _, _ -> failureCount += 1 }

        try {
            preloadManager.sync(listOf(unsupported), visibleRank = 0)
            preloadManager.sync(listOf(unsupported), visibleRank = 0)
            assertEquals(1, failureCount)

            preloadManager.sync(emptyList(), visibleRank = 0)
            preloadManager.sync(listOf(unsupported), visibleRank = 0)
            assertEquals(2, failureCount)
        } finally {
            preloadManager.release()
        }
    }

    @Test
    fun preload_rotatedSignedUriWithStableCacheKey_replacesExpiredRequest() {
        val preloadManager = FeedPreloadManager(ApplicationProvider.getApplicationContext<Application>())
        val original = source("a", 0, "https://cdn.test/video.mp4?sig=expired").copy(cacheKey = "stable")
        val rotated = original.copy(uri = "https://cdn.test/video.mp4?sig=current")
        try {
            preloadManager.sync(listOf(original), visibleRank = 0)
            assertNotNull(preloadManager.mediaSourceFor(original))
            assertNull(preloadManager.mediaSourceFor(rotated))

            preloadManager.sync(listOf(rotated), visibleRank = 0)
            assertEquals(1, preloadManager.sourceCount())
            assertNull(preloadManager.mediaSourceFor(original))
            val refreshed = assertNotNull(preloadManager.mediaSourceFor(rotated))
            assertEquals(rotated.uri, refreshed.mediaItem.localConfiguration?.uri.toString())
        } finally {
            preloadManager.release()
        }
    }

    @Test
    fun preload_sameUriWithDifferentCredentialsOrKind_hasDistinctMediaItems() {
        val preloadManager = FeedPreloadManager(ApplicationProvider.getApplicationContext<Application>())
        val original = source("a", 0, "https://cdn.test/video.mp4").copy(cacheKey = "stable")
        val sources = listOf(
            original,
            original.copy(id = "private", headers = mapOf("Authorization" to "Bearer private")),
            original.copy(id = "hls", kind = FeedMediaKindMessage.HLS),
            original.copy(id = "other", cacheKey = "other")
        )
        try {
            preloadManager.sync(sources, visibleRank = 0)
            val mediaItems = sources.map { assertNotNull(preloadManager.mediaSourceFor(it)).mediaItem }
            assertEquals(4, preloadManager.sourceCount())
            assertEquals(4, mediaItems.toSet().size)
            for ((source, item) in sources.zip(mediaItems)) {
                assertEquals(source.requestIdentity, item.mediaId)
            }
        } finally {
            preloadManager.release()
        }
    }

    @Test
    fun preload_failedRequestDoesNotSuppressReplacementWithSameDiskIdentity() {
        val preloadManager = FeedPreloadManager(ApplicationProvider.getApplicationContext<Application>())
        val original = source("a", 0, "https://cdn.test/video.mpd").copy(cacheKey = "stable")
        val replacement = original.copy(uri = "https://cdn.test/video.mp4")
        var failures = 0
        preloadManager.onSourceFailed = { _, _ -> failures += 1 }
        try {
            preloadManager.sync(listOf(original), visibleRank = 0)
            assertEquals(1, failures)
            preloadManager.sync(listOf(replacement), visibleRank = 0)
            assertNotNull(preloadManager.mediaSourceFor(replacement))
            assertEquals(1, failures)
        } finally {
            preloadManager.release()
        }
    }

    private fun delegate(manager: FeedPreloadManager): DefaultPreloadManager =
        FeedPreloadManager::class.java.getDeclaredField("delegate").apply { isAccessible = true }
            .get(manager) as DefaultPreloadManager

    private fun holders(manager: FeedPreloadManager): Map<String, Any> {
        val holders = BasePreloadManager::class.java.getDeclaredField("sourceHolderPriorityList")
            .apply { isAccessible = true }.get(delegate(manager)) as List<*>
        return holders.filterNotNull().associateBy { holder ->
            val item = holder.javaClass.getField("mediaItem").apply { isAccessible = true }
                .get(holder) as MediaItem
            item.mediaId
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun assertRankingAndTargets(
        manager: FeedPreloadManager,
        window: List<RegisteredSource>,
        visibleRank: Int
    ) {
        val delegate = delegate(manager)
        val holders = holders(manager)
        val control = BasePreloadManager::class.java.getDeclaredField("targetPreloadStatusControl")
            .apply { isAccessible = true }.get(delegate) as
            TargetPreloadStatusControl<Int, DefaultPreloadManager.PreloadStatus>
        val comparator = BasePreloadManager::class.java.getDeclaredField("rankingDataComparator")
            .apply { isAccessible = true }.get(delegate) as Comparator<Int>
        val registeredRanks = FeedPreloadManager::class.java.getDeclaredField("registeredRanks")
            .apply { isAccessible = true }.get(manager) as Map<Int, Int>
        val tokens = window.associateWith { source ->
            val holder = holders.getValue(source.requestIdentity)
            holder.javaClass.getField("rankingData").apply { isAccessible = true }.get(holder) as Int
        }
        for ((source, token) in tokens) {
            assertEquals(source.rank, registeredRanks[token])
            val expected = when (abs(source.rank - visibleRank)) {
                0 -> DefaultPreloadManager.PreloadStatus.PRELOAD_STATUS_NOT_PRELOADED
                1 -> DefaultPreloadManager.PreloadStatus.specifiedRangeLoaded(3_000L)
                else -> DefaultPreloadManager.PreloadStatus.PRELOAD_STATUS_TRACKS_SELECTED
            }
            assertEquals(expected, control.getTargetPreloadStatus(token))
            for ((other, otherToken) in tokens) {
                assertEquals(
                    abs(source.rank - visibleRank).compareTo(abs(other.rank - visibleRank)),
                    comparator.compare(token, otherToken)
                )
            }
        }
    }

    @Test
    fun preload_alternatingRepeatedIdentities_followNearestRankBeyondWindow_withoutRegistrationChurn() {
        MediaCache.resetForTesting()
        val preloadManager = FeedPreloadManager(ApplicationProvider.getApplicationContext<Application>())
        val registry = FeedSourceRegistry()
        val sources = (0..13).map { rank ->
            source("item-$rank", rank, "https://cdn.test/${rank % 2}.mp4")
        }
        registry.replaceAll(sources)
        try {
            registry.setVisible(sources.first().id)
            preloadManager.sync(registry.preloadWindow(2, 1), 0)
            val originalHolders = holders(preloadManager)
            val originalMediaSources = registry.preloadWindow(2, 1).associate {
                it.requestIdentity to assertNotNull(preloadManager.mediaSourceFor(it))
            }
            for (visible in sources + sources.reversed()) {
                registry.setVisible(visible.id)
                val window = registry.preloadWindow(2, 1)
                preloadManager.sync(window, visible.rank)
                assertEquals(2, preloadManager.sourceCount())
                assertRankingAndTargets(preloadManager, window, visible.rank)
                for (source in window) {
                    assertSame(originalHolders[source.requestIdentity], holders(preloadManager)[source.requestIdentity])
                    assertSame(originalMediaSources[source.requestIdentity], preloadManager.mediaSourceFor(source))
                }
                preloadManager.sync(window, visible.rank)
                assertRankingAndTargets(preloadManager, window, visible.rank)
                for (source in window) {
                    assertSame(originalHolders[source.requestIdentity], holders(preloadManager)[source.requestIdentity])
                }
            }
        } finally {
            preloadManager.release()
        }
    }

    @Test
    fun preload_reorderedSameIdentities_updatePriorityAndTarget_withoutReplacingSharedSource() {
        MediaCache.resetForTesting()
        val preloadManager = FeedPreloadManager(ApplicationProvider.getApplicationContext<Application>())
        val initial = (0..2).map { source("item-$it", it, "https://cdn.test/$it.mp4") }
        val reordered = listOf(initial[0].copy(rank = 2), initial[1].copy(rank = 0), initial[2].copy(rank = 1))
        val player = preloadManager.buildPlayer()
        try {
            preloadManager.sync(initial, 0)
            val shared = assertNotNull(preloadManager.mediaSourceFor(initial[0]))
            player.setMediaSource(shared)
            val originalHolders = holders(preloadManager)
            assertRankingAndTargets(preloadManager, initial, 0)
            preloadManager.sync(reordered, 0)
            assertRankingAndTargets(preloadManager, reordered, 0)
            assertSame(shared, preloadManager.mediaSourceFor(reordered[0]))
            for (source in reordered) {
                assertSame(originalHolders[source.requestIdentity], holders(preloadManager)[source.requestIdentity])
            }
            preloadManager.sync(reordered, 0)
            for (source in reordered) {
                assertSame(originalHolders[source.requestIdentity], holders(preloadManager)[source.requestIdentity])
            }
        } finally {
            player.release()
            preloadManager.release()
        }
    }

    @Test
    fun recycledPlayer_resetsPlaybackSpeed() {
        val manager = manager()
        manager.initialize(config())
        manager.setSources(listOf(source("a", 0, "https://example.test/a.mp4")))

        manager.createController(controllerId = 1, sourceId = "a", autoPlay = false, looping = false)
        manager.setPlaybackSpeed(1, 2.0)
        assertEquals(2f, assertNotNull(manager.playerFor(1)).playbackParameters.speed)

        manager.disposeController(1)
        manager.createController(controllerId = 2, sourceId = "a", autoPlay = false, looping = false)

        assertEquals(1f, assertNotNull(manager.playerFor(2)).playbackParameters.speed)
    }

    @Test
    fun activeLimitEviction_sparesTheVisibleController_andEvictsTheFurthest() {
        val released = mutableListOf<Pair<Int, ReleaseReasonMessage>>()
        val context = ApplicationProvider.getApplicationContext<Application>()
        val manager = ExoPlayerManager(
            context = context,
            onState = { _, _, _ -> },
            onReleased = { id, reason -> released.add(id to reason) },
            onPosition = { _ -> },
            onMetrics = { _ -> },
            onVideoSize = { _ -> }
        ).also(managers::add)
        manager.initialize(config(maxActivePlayers = 2, preloadAhead = 2, preloadBehind = 0))
        manager.setSources(
            listOf(
                source("v", 0, "https://example.test/v.mp4"),
                source("near", 1, "https://example.test/near.mp4"),
                source("far", 5, "https://example.test/far.mp4")
            )
        )

        manager.createController(controllerId = 1, sourceId = "v", autoPlay = false, looping = false)
        manager.createController(controllerId = 2, sourceId = "near", autoPlay = false, looping = false)
        manager.setVisibleSource("v")
        manager.createController(controllerId = 3, sourceId = "far", autoPlay = false, looping = false)

        // The active-limit eviction picks the furthest eligible controller and
        // never the one playing the visible source.
        assertEquals(listOf(2 to ReleaseReasonMessage.EVICTED), released)
        assertNotNull(manager.playerFor(1))
        assertEquals(2, manager.activeControllerCount())
    }

    @Test
    fun recycledPlayer_keepsPreloadPairing() {
        val manager = manager()
        manager.initialize(config(maxActivePlayers = 2, preloadAhead = 1, preloadBehind = 0))
        // Let the deferred preload-manager build run so players come from its builder.
        shadowOf(Looper.getMainLooper()).idle()
        manager.setSources(
            listOf(
                source("a", 0, "https://example.test/a.mp4"),
                source("b", 1, "https://example.test/b.mp4")
            )
        )
        manager.setVisibleSource("a")
        shadowOf(Looper.getMainLooper()).idle()

        manager.createController(controllerId = 1, sourceId = "a", autoPlay = false, looping = false)
        assertTrue(manager.playerCameFromPreloadManager(1))

        manager.disposeController(1)
        shadowOf(Looper.getMainLooper()).idle()
        manager.createController(controllerId = 2, sourceId = "b", autoPlay = false, looping = false)

        // The recycled player must still be recognised as builder-paired.
        assertTrue(manager.playerCameFromPreloadManager(2))
    }
}

/** Pooling semantics; Robolectric supplies the application context. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
internal class TextureViewPoolTest {
    @Test
    fun release_clearsSurfaceTextureListener_andPoolsTheView() {
        val pool = TextureViewPool(maxPoolSize = 2)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val view = pool.acquire(context)
        view.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(
                surface: SurfaceTexture,
                width: Int,
                height: Int
            ) = Unit

            override fun onSurfaceTextureSizeChanged(
                surface: SurfaceTexture,
                width: Int,
                height: Int
            ) = Unit

            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true

            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
        }

        pool.release(view)

        assertNull(view.surfaceTextureListener)
        assertTrue(pool.acquire(context) === view)
    }

    @Test
    fun clear_emptiesThePool_soActivityBoundViewsAreDropped() {
        val pool = TextureViewPool(maxPoolSize = 4)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val first = pool.acquire(context)
        val second = pool.acquire(context)
        pool.release(first)
        pool.release(second)

        pool.clear()

        val third = pool.acquire(context)
        assertTrue(third !== first)
        assertTrue(third !== second)
    }

    @Test
    fun release_beyondMaxPoolSize_dropsTheView() {
        val pool = TextureViewPool(maxPoolSize = 1)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val first = pool.acquire(context)
        val second = pool.acquire(context)

        pool.release(first)
        pool.release(second)

        assertTrue(pool.acquire(context) === first)
    }
}
