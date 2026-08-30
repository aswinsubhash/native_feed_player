package io.github.aswinsubhash.native_feed_player

import android.view.Surface
import org.mockito.Mockito.mock
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

internal class PlatformViewRegistryTest {
    @Test
    fun staleDisposalDoesNotRemoveReplacementView() {
        val registry = PlatformViewRegistry<Int, Any>()
        val oldView = Any()
        val newView = Any()

        registry.register(7, oldView)
        registry.register(7, newView)

        assertFalse(registry.removeIfCurrent(7, oldView))
        assertSame(newView, registry[7])
    }

    @Test
    fun currentViewIsRemovedExactlyOnce() {
        val registry = PlatformViewRegistry<Int, Any>()
        val view = Any()

        registry.register(7, view)

        assertTrue(registry.removeIfCurrent(7, view))
        assertNull(registry[7])
        assertFalse(registry.removeIfCurrent(7, view))
    }

    @Test
    fun controllerRelease_removesAllStaleViewMappingsBeforeLifecycleEmission() {
        val mappings = mutableMapOf(10 to 7, 11 to 7, 12 to 8)
        val observations = mutableListOf<Map<Int, Int>>()

        removeControllerViewMappings(mappings, 7)
        observations += mappings.toMap() // Represents the lifecycle event observer.

        assertEquals(mapOf(12 to 8), observations.single())
    }

    @Test
    fun textureOutput_detachUnbindsAndReleasesExactlyOnce() {
        val surface = mock(Surface::class.java)
        var releases = 0
        var unbinds = 0
        val registry = TextureOutputRegistry {
            TextureOutput(id = 42, surface = surface) { releases += 1 }
        }

        assertEquals(42, registry.attach(7) {})
        registry.detach(7) { unbinds += 1 }
        registry.detach(7) { unbinds += 1 }

        assertEquals(1, unbinds)
        assertEquals(1, releases)
        assertFalse(registry.isAttached(7))
    }

    @Test
    fun textureOutput_clearUnbindsAndReleasesEveryController() {
        var nextId = 1L
        var releases = 0
        val registry = TextureOutputRegistry {
            TextureOutput(id = nextId++, surface = mock(Surface::class.java)) { releases += 1 }
        }
        registry.attach(1) {}
        registry.attach(2) {}
        val unbound = mutableSetOf<Int>()

        registry.clear { controllerId, _ -> unbound += controllerId }

        assertEquals(setOf(1, 2), unbound)
        assertEquals(2, releases)
        assertFalse(registry.isAttached(1))
        assertFalse(registry.isAttached(2))
    }
}
