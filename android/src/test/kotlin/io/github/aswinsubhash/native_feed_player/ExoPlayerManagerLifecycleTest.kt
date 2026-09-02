package io.github.aswinsubhash.native_feed_player

import android.app.Application
import android.content.ComponentCallbacks2
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
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
