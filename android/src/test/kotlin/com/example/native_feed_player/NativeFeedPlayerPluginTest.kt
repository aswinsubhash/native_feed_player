package com.example.native_feed_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/*
 * Unit tests for the Kotlin portion of this plugin.
 *
 * Run from the `example/android/` directory with `./gradlew testDebugUnitTest`,
 * or from an IDE with JUnit support.
 */
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
