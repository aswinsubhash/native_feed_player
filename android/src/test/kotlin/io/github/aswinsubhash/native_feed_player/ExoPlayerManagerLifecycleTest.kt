package io.github.aswinsubhash.native_feed_player

import android.app.Application
import android.content.ComponentCallbacks2
import android.os.Looper
import androidx.media3.common.Player
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
internal class ExoPlayerManagerLifecycleTest {
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

    private fun manager(
        onReleased: (controllerId: Int, reason: ReleaseReasonMessage) -> Unit = { _, _ -> }
    ): ExoPlayerManager {
        val context = ApplicationProvider.getApplicationContext<Application>()
        return ExoPlayerManager(
            context = context,
            onState = { _, _, _ -> },
            onReleased = onReleased,
            onPosition = { _ -> },
            onMetrics = { _ -> },
            onVideoSize = { _ -> }
        ).also(managers::add)
    }

    private fun source(id: String, rank: Int) = RegisteredSource(
        id = id,
        uri = "file:///dev/null/$id.mp4",
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
    fun initialize_replacesPreviousSession_andReleasesControllers() {
        val released = mutableListOf<Pair<Int, ReleaseReasonMessage>>()
        val manager = manager { id, reason -> released.add(id to reason) }
        manager.initialize(config())
        manager.setSources(listOf(source("a", 0)))
        manager.createController(controllerId = 1, sourceId = "a", autoPlay = false, looping = false)

        manager.initialize(config())

        assertEquals(listOf(1 to ReleaseReasonMessage.DISPOSED), released)
        assertEquals(0, manager.activeControllerCount())
        assertEquals(0, manager.scheduledPreloadCount())
        assertNull(manager.cacheIdentity("a"))
    }

    @Test
    fun setSources_rotatingSignedUriWithStableCacheKey_releasesNativeController() {
        val released = mutableListOf<Pair<Int, ReleaseReasonMessage>>()
        val manager = manager { id, reason -> released.add(id to reason) }
        val original = source("a", 0).copy(cacheKey = "stable")
        manager.initialize(config())
        manager.setSources(listOf(original))
        manager.createController(1, "a", autoPlay = false, looping = false)
        val diskIdentity = manager.cacheIdentity("a")

        manager.setSources(listOf(original.copy(uri = "${original.uri}?sig=new")))

        assertEquals(diskIdentity, manager.cacheIdentity("a"))
        assertEquals(listOf(1 to ReleaseReasonMessage.DISPOSED), released)
        assertNull(manager.playerFor(1))
    }

    @Test
    fun setSources_headerNormalizationPreservesController_butCacheKeyChangeReleasesIt() {
        val manager = manager()
        val original = source("a", 0).copy(headers = mapOf("Authorization" to "Bearer one"), cacheKey = "stable")
        manager.initialize(config())
        manager.setSources(listOf(original))
        manager.createController(1, "a", autoPlay = false, looping = false)
        val player = assertNotNull(manager.playerFor(1))

        manager.setSources(listOf(original.copy(headers = mapOf("authorization" to "Bearer one"))))
        assertTrue(player === manager.playerFor(1))
        manager.setSources(listOf(original.copy(cacheKey = "replacement")))
        assertNull(manager.playerFor(1))
    }

    @Test
    fun background_pausesBufferingIntent_andRepeatedNotificationsPreserveResumeIntent() {
        val manager = manager()
        manager.initialize(config())
        manager.setSources(listOf(source("a", 0)))
        manager.createController(1, "a", autoPlay = true, looping = false)
        val player = assertNotNull(manager.playerFor(1))
        assertEquals(Player.STATE_BUFFERING, player.playbackState)
        assertFalse(player.isPlaying)
        assertTrue(player.playWhenReady)

        manager.onAppBackgrounded()
        assertFalse(player.playWhenReady)
        manager.onAppBackgrounded()
        manager.onAppForegrounded()
        assertTrue(player.playWhenReady)
    }

    @Test
    fun background_createAndPlayDeferIntent_andPauseCancelsResume() {
        val manager = manager()
        manager.initialize(config())
        manager.setSources(listOf(source("a", 0)))
        manager.onAppBackgrounded()
        manager.createController(1, "a", autoPlay = true, looping = false)
        manager.createController(2, "a", autoPlay = false, looping = false)
        manager.createController(3, "a", autoPlay = false, looping = false)
        val autoplay = assertNotNull(manager.playerFor(1))
        val requested = assertNotNull(manager.playerFor(2))
        val paused = assertNotNull(manager.playerFor(3))
        manager.play(2)
        manager.pause(1)
        assertFalse(autoplay.playWhenReady)
        assertFalse(requested.playWhenReady)
        assertFalse(paused.playWhenReady)

        manager.onAppForegrounded()
        assertFalse(autoplay.playWhenReady)
        assertTrue(requested.playWhenReady)
        assertFalse(paused.playWhenReady)
    }

    @Test
    fun background_autoplayResumesButDisposedIntentDoesNotSurviveControllerReuse() {
        val manager = manager()
        manager.initialize(config())
        manager.setSources(listOf(source("a", 0)))
        manager.onAppBackgrounded()
        manager.createController(1, "a", autoPlay = true, looping = false)
        manager.createController(2, "a", autoPlay = true, looping = false)
        manager.disposeController(2)
        manager.createController(2, "a", autoPlay = false, looping = false)
        assertFalse(assertNotNull(manager.playerFor(1)).playWhenReady)

        manager.onAppForegrounded()
        assertTrue(assertNotNull(manager.playerFor(1)).playWhenReady)
        assertFalse(assertNotNull(manager.playerFor(2)).playWhenReady)
    }

    @Test
    fun initializeWhileBackgrounded_doesNotEnableAutoplay() {
        val manager = manager()
        manager.onAppBackgrounded()
        manager.initialize(config())
        manager.setSources(listOf(source("a", 0)))
        manager.createController(1, "a", autoPlay = true, looping = false)
        assertFalse(assertNotNull(manager.playerFor(1)).playWhenReady)
        manager.onAppForegrounded()
        assertTrue(assertNotNull(manager.playerFor(1)).playWhenReady)
    }

    @Test
    fun duplicateSourceCreation_evictsOldestWithinBudget() {
        val released = mutableListOf<Pair<Int, ReleaseReasonMessage>>()
        val manager = manager { id, reason -> released.add(id to reason) }
        manager.initialize(config(maxActivePlayers = 2, preloadAhead = 0, preloadBehind = 0))
        manager.setSources(listOf(source("only", 0)))

        manager.createController(controllerId = 1, sourceId = "only", autoPlay = false, looping = false)
        manager.createController(controllerId = 2, sourceId = "only", autoPlay = false, looping = false)
        manager.createController(controllerId = 3, sourceId = "only", autoPlay = false, looping = false)

        assertEquals(2, manager.activeControllerCount())
        assertEquals(listOf(1 to ReleaseReasonMessage.EVICTED), released)
    }

    @Test
    fun criticalMemoryPressure_clearsPreloads_andRecoversOnNextInteraction() {
        val manager = manager()
        manager.initialize(config(preloadAhead = 2, preloadBehind = 1))
        manager.setSources(
            listOf(
                source("visible", 0),
                source("next", 1),
                source("far", 2)
            )
        )
        manager.setVisibleSource("visible")
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(manager.scheduledPreloadCount() > 0)

        manager.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)

        assertEquals(0, manager.scheduledPreloadCount())
        manager.setVisibleSource("next")
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(manager.scheduledPreloadCount() > 0)
    }

    @Test
    fun disposeAll_releasesEveryControllerWithEngineDetachedReason() {
        val released = mutableListOf<Pair<Int, ReleaseReasonMessage>>()
        val manager = manager { id, reason -> released.add(id to reason) }
        manager.initialize(config())
        manager.setSources(listOf(source("a", 0), source("b", 1)))
        manager.createController(controllerId = 1, sourceId = "a", autoPlay = false, looping = false)
        manager.createController(controllerId = 2, sourceId = "b", autoPlay = false, looping = false)

        manager.disposeAll()

        assertEquals(
            setOf(1 to ReleaseReasonMessage.ENGINE_DETACHED, 2 to ReleaseReasonMessage.ENGINE_DETACHED),
            released.toSet()
        )
        assertEquals(0, manager.activeControllerCount())
    }
}
