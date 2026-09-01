package io.github.aswinsubhash.native_feed_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class NativeFeedPlayerPluginTest {
    private fun config() = FeedPlayerConfigMessage(
        maxActivePlayers = 3,
        preloadAhead = 2,
        preloadBehind = 1,
        maxConcurrentPreloads = 2,
        positionUpdateIntervalMs = 200,
        renderMode = RenderModeMessage.PLATFORM_VIEW,
        cache = CachePolicyMessage(enabled = true, maxBytes = 256L * 1024 * 1024),
        audio = AudioPolicyMessage(muted = true, volume = 1.0, handleAudioFocus = false)
    )

    @Test
    fun initialize_withoutAttachment_throwsFlutterError() {
        val plugin = NativeFeedPlayerPlugin()

        val error = assertFailsWith<FlutterError> {
            plugin.initialize(config())
        }

        assertEquals("not_attached", error.code)
    }

    @Test
    fun createController_withBlankSourceId_isRejected() {
        val plugin = NativeFeedPlayerPlugin()

        val error = assertFailsWith<FlutterError> {
            plugin.createController(
                CreateControllerRequest(sourceId = "", autoPlay = false, looping = true)
            )
        }

        assertEquals("invalid_source", error.code)
    }
}

internal class PendingCacheOperationsTest {
    @Test
    fun registeredOperation_completesExactlyOnce() {
        val operations = PendingCacheOperations()
        val token = operations.register(onDetached = {})

        assertTrue(operations.complete(token!!))
        assertFalse(operations.complete(token))
    }

    @Test
    fun detach_failsEveryPendingOperationOnce() {
        val operations = PendingCacheOperations()
        var detachedCalls = 0
        val first = operations.register { detachedCalls += 1 }
        val second = operations.register { detachedCalls += 1 }

        val canceled = operations.detach()

        assertEquals(2, canceled)
        assertEquals(2, detachedCalls)
        // Tokens are already consumed; late worker completions are no-ops.
        assertFalse(operations.complete(first!!))
        assertFalse(operations.complete(second!!))
        assertEquals(2, detachedCalls)
    }

    @Test
    fun detach_rejectsNewOperations_untilReattached() {
        val operations = PendingCacheOperations()
        operations.detach()

        assertEquals(null, operations.register(onDetached = {}))
        assertTrue(operations.isDetached())

        operations.attach()

        assertTrue(operations.register(onDetached = {}) != null)
        assertFalse(operations.isDetached())
    }

    @Test
    fun complete_withUnknownToken_isRejected() {
        val operations = PendingCacheOperations()

        assertFalse(operations.complete(42L))
    }
}
