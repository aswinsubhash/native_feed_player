package io.github.aswinsubhash.native_feed_player

import android.content.ComponentCallbacks2
import androidx.media3.common.Player
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Verifies explicit classification of non-severity-ordered trim levels. */
internal class TrimMemoryClassificationTest {
    private enum class Pressure { NONE, MODERATE, CRITICAL }

    private fun classify(level: Int): Pressure = when (level) {
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
        ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> Pressure.CRITICAL

        ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW,
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE,
        ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN,
        ComponentCallbacks2.TRIM_MEMORY_BACKGROUND,
        ComponentCallbacks2.TRIM_MEMORY_MODERATE -> Pressure.MODERATE

        else -> Pressure.NONE
    }

    @Test
    fun uiHidden_isNotTreatedAsCritical() {
        assertEquals(Pressure.MODERATE, classify(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN))
    }

    @Test
    fun runningModerate_isHandled() {
        assertEquals(
            Pressure.MODERATE,
            classify(ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE)
        )
    }

    @Test
    fun runningCritical_isCritical() {
        assertEquals(
            Pressure.CRITICAL,
            classify(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)
        )
    }

    @Test
    fun complete_isCritical() {
        assertEquals(Pressure.CRITICAL, classify(ComponentCallbacks2.TRIM_MEMORY_COMPLETE))
    }

    @Test
    fun uiHiddenSortsAboveCritical_soOrderedComparisonWouldBeWrong() {
        assertTrue(
            ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN >
                ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
        )
    }
}

/** Verifies visibility-generation eviction rules. */
internal class VisibleWindowEvictionRuleTest {
    private data class Controller(val index: Int, val createdAtGeneration: Long)

    private fun evictable(
        controllers: Map<Int, Controller>,
        visibleIndex: Int,
        radius: Int,
        generation: Long,
        forceAggressive: Boolean = false
    ): Set<Int> {
        val effectiveRadius = if (forceAggressive) 0 else radius
        val min = visibleIndex - effectiveRadius
        val max = visibleIndex + effectiveRadius
        return controllers.filterValues { controller ->
            val outside = controller.index >= 0 &&
                (controller.index < min || controller.index > max)
            val measurable = forceAggressive || controller.createdAtGeneration != generation
            outside && measurable
        }.keys
    }

    @Test
    fun controllerCreatedBeforeVisibleIndexUpdate_isNotEvicted() {
        val controllers = mapOf(
            1 to Controller(index = 0, createdAtGeneration = 5),
            2 to Controller(index = 1, createdAtGeneration = 5),
            3 to Controller(index = 2, createdAtGeneration = 5)
        )

        val evicted = evictable(
            controllers = controllers,
            visibleIndex = 0,
            radius = 1,
            generation = 5
        )

        assertTrue(evicted.isEmpty(), "new controllers must survive until a window applies")
    }

    @Test
    fun staleControllerOutsideWindow_isEvicted() {
        val controllers = mapOf(
            1 to Controller(index = 0, createdAtGeneration = 4),
            2 to Controller(index = 9, createdAtGeneration = 4)
        )

        val evicted = evictable(
            controllers = controllers,
            visibleIndex = 0,
            radius = 1,
            generation = 5
        )

        assertEquals(setOf(2), evicted)
    }

    @Test
    fun aggressiveMode_ignoresGenerationGrace() {
        val controllers = mapOf(
            1 to Controller(index = 0, createdAtGeneration = 5),
            2 to Controller(index = 3, createdAtGeneration = 5)
        )

        val evicted = evictable(
            controllers = controllers,
            visibleIndex = 0,
            radius = 2,
            generation = 5,
            forceAggressive = true
        )

        assertEquals(setOf(2), evicted)
    }
}

internal class AdaptivePreloadPolicyTest {
    @Test
    fun clusteredRebuffersDegrade_butSparseRebuffersDoNot() {
        val policy = AdaptivePreloadPolicy()

        assertFalse(policy.recordRebuffer(0))
        assertFalse(policy.recordRebuffer(1_000))
        assertTrue(policy.recordRebuffer(2_000))
        assertEquals(0.5, policy.scale)

        assertFalse(policy.recordRebuffer(40_000))
        assertFalse(policy.recordRebuffer(80_000))
        assertFalse(policy.recordRebuffer(120_000))
        assertEquals(0.5, policy.scale)
    }

    @Test
    fun recoveryRequiresStableTime_andOccursOneStepPerInterval() {
        val policy = AdaptivePreloadPolicy()
        policy.recordRebuffer(0)
        policy.recordRebuffer(1)
        policy.recordRebuffer(2)
        policy.recordRebuffer(3)
        policy.recordRebuffer(4)
        policy.recordRebuffer(5)
        assertEquals(0.25, policy.scale)

        assertFalse(policy.recordSteadyPlayback(5 + AdaptivePreloadPolicy.RECOVERY_INTERVAL_MS - 1))
        assertTrue(policy.recordSteadyPlayback(5 + AdaptivePreloadPolicy.RECOVERY_INTERVAL_MS))
        assertEquals(0.5, policy.scale)
        assertFalse(policy.recordSteadyPlayback(5 + AdaptivePreloadPolicy.RECOVERY_INTERVAL_MS + 1))
        assertTrue(policy.recordSteadyPlayback(5 + 2 * AdaptivePreloadPolicy.RECOVERY_INTERVAL_MS))
        assertEquals(1.0, policy.scale)
    }
}

internal class PlaybackStatusMappingTest {
    @Test
    fun playerErrorAlwaysTakesPrecedence() {
        for (state in listOf(Player.STATE_IDLE, Player.STATE_BUFFERING, Player.STATE_READY, Player.STATE_ENDED)) {
            assertEquals(
                PlaybackStatusMessage.ERROR,
                mapPlaybackStatus(state, isPlaying = true, hasPlayerError = true, hasEverPlayed = true)
            )
        }
    }

    @Test
    fun readyPlaybackDistinguishesInitialReadyPlayingAndPaused() {
        assertEquals(
            PlaybackStatusMessage.READY,
            mapPlaybackStatus(Player.STATE_READY, false, false, false)
        )
        assertEquals(
            PlaybackStatusMessage.PLAYING,
            mapPlaybackStatus(Player.STATE_READY, true, false, true)
        )
        assertEquals(
            PlaybackStatusMessage.PAUSED,
            mapPlaybackStatus(Player.STATE_READY, false, false, true)
        )
        assertEquals(
            PlaybackStatusMessage.COMPLETED,
            mapPlaybackStatus(Player.STATE_ENDED, false, false, true)
        )
    }
}
