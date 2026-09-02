package io.github.aswinsubhash.native_feed_player

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.media3.datasource.cache.SimpleCache
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
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
        MediaCache.cacheFactory = null
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

    @Test
    fun configure_raceWithTeardown_releasesStaleCache_andKeepsDirectoryReusable() {
        val executor = Executors.newSingleThreadExecutor()
        val cacheBuilt = CountDownLatch(1)
        val releaseGate = CountDownLatch(1)
        var builtCount = 0
        MediaCache.cacheFactory = { dir, evictor, provider ->
            builtCount += 1
            cacheBuilt.countDown()
            val cache = SimpleCache(dir, evictor, provider)
            // Hold the configure task open so teardown() can race it.
            releaseGate.await()
            cache
        }
        try {
            MediaCache.configure(context, true, 1024L * 1024, executor)
            assertTrue(cacheBuilt.await(5, TimeUnit.SECONDS))

            // Teardown races the in-flight configure and bumps the generation.
            MediaCache.teardown()
            releaseGate.countDown()

            // The stale attempt must unwind without holding the directory.
            assertNull(MediaCache.awaitCache(timeoutMs = 10_000))
            assertNull(MediaCache.activeCache())

            // The directory lock must be free: a fresh configure succeeds.
            MediaCache.configure(context, true, 1024L * 1024, executor)
            assertNotNull(MediaCache.awaitCache(timeoutMs = 10_000))
            assertNotNull(MediaCache.activeCache())
            assertTrue(builtCount >= 2)
        } finally {
            releaseGate.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun teardown_unblocksAwaitCacheImmediately() {
        val executor = Executors.newSingleThreadExecutor()
        val releaseGate = CountDownLatch(1)
        MediaCache.cacheFactory = { dir, evictor, provider ->
            SimpleCache(dir, evictor, provider).also { releaseGate.await() }
        }
        try {
            MediaCache.configure(context, true, 1024L * 1024, executor)

            val awaiterResult = AtomicReference<Any?>(UNRESOLVED)
            val awaiter = Thread {
                awaiterResult.set(MediaCache.awaitCache(timeoutMs = 10_000))
            }
            awaiter.start()
            // Give the awaiter time to block on the pending future.
            Thread.sleep(100)
            assertEquals(UNRESOLVED, awaiterResult.get())

            val startedAt = System.nanoTime()
            MediaCache.teardown()
            awaiter.join(2_000)

            // The awaiter must have returned null well before its 10 s timeout.
            assertNull(awaiterResult.get())
            val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000
            assertTrue(elapsedMs < 2_000, "teardown() took ${elapsedMs}ms to unblock awaitCache")
        } finally {
            releaseGate.countDown()
            executor.shutdownNow()
        }
    }

    private companion object {
        /** Distinguishes "awaiter has not returned yet" from a null result. */
        val UNRESOLVED: Any = Any()
    }
}
