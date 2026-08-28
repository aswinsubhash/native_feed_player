package io.github.aswinsubhash.native_feed_player

import android.content.ComponentCallbacks2
import kotlin.test.Test
import kotlin.test.assertEquals
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
