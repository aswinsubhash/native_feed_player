package io.github.aswinsubhash.native_feed_player

import kotlin.test.Test
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
}
