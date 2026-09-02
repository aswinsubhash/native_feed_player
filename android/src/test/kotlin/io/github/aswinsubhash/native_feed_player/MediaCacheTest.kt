package io.github.aswinsubhash.native_feed_player

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Exercises the async cache lifecycle with a direct executor so configure
 * completes synchronously, mirroring the production ordering on the cache
 * executor thread.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
internal class MediaCacheTest {
    private val context = ApplicationProvider.getApplicationContext<android.app.Application>()

    @After
    fun tearDown() {
        MediaCache.resetForTesting()
    }

    @Test
    fun configure_withDirectExecutor_opensCacheSynchronously() {
        MediaCache.configure(
            context = context,
            enabled = true,
            maxBytes = 1024L * 1024,
            executor = Runnable::run
        )

        assertTrue(MediaCache.isReady)
        assertNotNull(MediaCache.activeCache())
        assertTrue(MediaCache.isEnabled())
        assertTrue(MediaCache.usageBytes() >= 0L)
    }

    @Test
    fun configure_disabled_tearsDown() {
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        MediaCache.configure(context, false, 0, Runnable::run)

        assertFalse(MediaCache.isEnabled())
        assertNull(MediaCache.activeCache())
        assertFalse(MediaCache.isReady)
    }

    @Test
    fun awaitCache_beforeConfigure_returnsNullWithoutBlocking() {
        assertNull(MediaCache.awaitCache(timeoutMs = 1))
        assertFalse(MediaCache.isEnabled())
    }

    @Test
    fun retainRelease_tearsDownOnlyAtZeroReferences() {
        MediaCache.retain()
        MediaCache.retain()
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val first = assertNotNull(MediaCache.activeCache())

        // One engine detaches; the other still plays through the cache.
        MediaCache.release()
        assertTrue(MediaCache.isEnabled())

        // Last detach closes the cache and frees the directory lock.
        MediaCache.release()
        assertFalse(MediaCache.isEnabled())
        assertNull(MediaCache.activeCache())
        assertNotEquals(first, MediaCache.activeCache())
    }

    @Test
    fun configure_whileAnotherEngineHoldsTheCache_keepsTheLiveInstance() {
        MediaCache.retain()
        MediaCache.retain()
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val live = assertNotNull(MediaCache.activeCache())

        // A second engine configuring a different budget must not release the
        // cache under the first engine.
        MediaCache.configure(context, true, 2048L * 1024, Runnable::run)

        assertEquals(live, MediaCache.activeCache())
        assertTrue(MediaCache.isEnabled())
    }

    @Test
    fun configure_sameBudget_isIdempotent() {
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val live = assertNotNull(MediaCache.activeCache())

        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)

        assertEquals(live, MediaCache.activeCache())
    }

    @Test
    fun cacheKey_overridesUriInIdentity_butHeadersStillMatter() {
        val base = CacheIdentity.forSource(
            uri = "https://cdn.test/video.mp4?sig=one",
            headers = emptyMap(),
            cacheKey = "episode-42"
        )
        val rotatedSignature = CacheIdentity.forSource(
            uri = "https://cdn.test/video.mp4?sig=two",
            headers = emptyMap(),
            cacheKey = "episode-42"
        )
        val differentKey = CacheIdentity.forSource(
            uri = "https://cdn.test/video.mp4?sig=one",
            headers = emptyMap(),
            cacheKey = "episode-43"
        )
        val differentHeaders = CacheIdentity.forSource(
            uri = "https://cdn.test/video.mp4?sig=one",
            headers = mapOf("Authorization" to "Bearer t"),
            cacheKey = "episode-42"
        )

        assertEquals(base, rotatedSignature)
        assertNotEquals(base, differentKey)
        assertNotEquals(base, differentHeaders)
    }
}
