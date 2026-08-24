package com.example.native_feed_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class NativeFeedPlayerPluginTest {
    @Test
    fun initialize_withoutAttachment_throwsFlutterError() {
        val plugin = NativeFeedPlayerPlugin()

        val error = assertFailsWith<FlutterError> {
            plugin.initialize(InitializeRequest(maxCachedPlayers = 5, preloadCount = 2))
        }

        assertEquals("not_attached", error.code)
    }
}
