package io.github.aswinsubhash.native_feed_player

import android.app.Application
import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Looper
import android.view.TextureView
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
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
