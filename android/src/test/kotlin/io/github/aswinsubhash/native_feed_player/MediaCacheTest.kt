package io.github.aswinsubhash.native_feed_player

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.ContentMetadataMutations
import androidx.media3.datasource.cache.SimpleCache
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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

    private fun source(kind: FeedMediaKindMessage = FeedMediaKindMessage.PROGRESSIVE) = RegisteredSource(
        id = "video",
        uri = "https://cdn.test/video.mp4?sig=old",
        rank = 0,
        kind = kind,
        headers = mapOf("Authorization" to "Bearer one"),
        cacheKey = "stable-video"
    )

    private fun cacheBytes(
        key: String,
        bytes: ByteArray,
        position: Long = 0,
        contentLength: Long = bytes.size.toLong()
    ) {
        val cache = assertNotNull(MediaCache.activeCache())
        val hole = assertNotNull(cache.startReadWrite(key, position, bytes.size.toLong()))
        try {
            val file = cache.startFile(key, position, bytes.size.toLong())
            file.writeBytes(bytes)
            cache.commitFile(file, bytes.size.toLong())
            val metadata = ContentMetadataMutations()
            ContentMetadataMutations.setContentLength(metadata, contentLength)
            cache.applyContentMetadataMutations(key, metadata)
        } finally {
            cache.releaseHoleSpan(hole)
        }
    }

    @Test
    fun progressiveTopLevelCacheKey_reusesSignedUrlsAndPartitionsCredentials() {
        for (kind in listOf(FeedMediaKindMessage.PROGRESSIVE, FeedMediaKindMessage.AUTO)) {
            val original = source(kind)
            val rotated = original.copy(uri = "https://cdn.test/video.mp4?sig=current")
            val key = CacheIdentity.cacheKey(original, original.uri)
            assertEquals(key, CacheIdentity.cacheKey(rotated, rotated.uri))
            val privateSource = rotated.copy(headers = mapOf("Authorization" to "Bearer two"))
            assertNotEquals(key, CacheIdentity.cacheKey(privateSource, privateSource.uri))
            assertNotEquals(key, CacheIdentity.cacheKey(original, "${original.uri}&child=1"))
            val withoutStableKey = original.copy(cacheKey = null)
            val rotatedWithoutStableKey = rotated.copy(cacheKey = null)
            assertNotEquals(
                CacheIdentity.cacheKey(withoutStableKey, withoutStableKey.uri),
                CacheIdentity.cacheKey(rotatedWithoutStableKey, rotatedWithoutStableKey.uri)
            )
        }
    }

    @Test
    fun adaptiveCacheKeys_keepExactManifestAndChildRequestUris() {
        for (kind in listOf(FeedMediaKindMessage.HLS, FeedMediaKindMessage.AUTO)) {
            val original = source(kind).copy(uri = "https://cdn.test/video.m3u8?sig=old")
            val rotated = original.copy(uri = "https://cdn.test/video.m3u8?sig=current")
            assertNotEquals(
                CacheIdentity.cacheKey(original, original.uri),
                CacheIdentity.cacheKey(rotated, rotated.uri)
            )
            val requests = listOf(
                "https://cdn.test/segment.ts?part=1",
                "https://cdn.test/segment.ts?part=2",
                "https://cdn.test/segment.ts?part=1&sig=new",
                "https://cdn.test/key?version=1"
            )
            assertEquals(requests.size, requests.map { CacheIdentity.cacheKey(original, it) }.toSet().size)
            for (request in requests) {
                assertEquals(CacheIdentity.cacheKey(original, request), CacheIdentity.cacheKey(rotated, request))
            }
        }
    }

    @Test
    fun dataSource_readsPreviouslyCachedProgressiveBytesAfterSignedUriRotation() {
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val original = source()
        val rotated = original.copy(uri = "https://cdn.test/video.mp4?sig=current")
        val expected = byteArrayOf(1, 2, 3, 4)
        cacheBytes(CacheIdentity.cacheKey(original, original.uri), expected)
        val dataSource = MediaCache.createDataSourceFactory(rotated).createDataSource()
        try {
            assertEquals(4L, dataSource.open(DataSpec.Builder().setUri(rotated.uri).setLength(4).build()))
            val actual = ByteArray(4)
            var offset = 0
            while (offset < actual.size) {
                val count = dataSource.read(actual, offset, actual.size - offset)
                assertTrue(count > 0)
                offset += count
            }
            assertTrue(expected.contentEquals(actual))
        } finally {
            dataSource.close()
        }
    }

    @Test
    fun cacheStatus_hlsKnownResourcesDoNotImplyWholeMediaCompleteness_andSnapshotIsStable() {
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val manager = ExoPlayerManager(context, { _, _, _ -> }, { _, _ -> }, { _ -> }, { _ -> }, { _ -> })
        val hls = source(FeedMediaKindMessage.HLS).copy(uri = "https://cdn.test/media")
        cacheBytes(CacheIdentity.cacheKey(hls, hls.uri), byteArrayOf(1, 2, 3, 4))
        try {
            manager.setSources(listOf(hls))
            val snapshot = assertNotNull(manager.cacheStatusSnapshot(hls.id))
            manager.setSources(listOf(hls.copy(kind = FeedMediaKindMessage.PROGRESSIVE)))
            val status = manager.cacheStatus(hls.id, snapshot)
            assertEquals(4L, status.cachedBytes)
            assertEquals(4L, status.totalBytes)
            assertFalse(status.isComplete)
            assertFalse(manager.cacheStatus(hls.id, manager.cacheStatusSnapshot(hls.id)).isComplete)
            val progressive = hls.copy(kind = FeedMediaKindMessage.PROGRESSIVE)
            cacheBytes(CacheIdentity.cacheKey(progressive, progressive.uri), byteArrayOf(1, 2, 3, 4))
            assertTrue(manager.cacheStatus(hls.id, manager.cacheStatusSnapshot(hls.id)).isComplete)
            assertFalse(manager.cacheStatus(hls.id, snapshot).isComplete)
            manager.setSources(listOf(hls.copy(kind = FeedMediaKindMessage.AUTO, uri = "https://cdn.test/media.m3u8")))
            assertFalse(manager.cacheStatus(hls.id, manager.cacheStatusSnapshot(hls.id)).isComplete)
            assertFalse(manager.cacheStatus("missing", manager.cacheStatusSnapshot("missing")).isComplete)
        } finally {
            manager.disposeAll()
        }
    }

    @Test
    fun cacheStatus_legacyProgressiveEntriesAreNotPlaybackHits_orCompletenessEvidence() {
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val source = source()
        val legacyKey = CacheIdentity.cacheKey(source.cacheIdentity, source.uri)
        val unversionedKey = "${source.cacheIdentity}/progressive"
        val rootKey = CacheIdentity.cacheKey(source, source.uri)
        val expected = byteArrayOf(1, 2, 3, 4)
        cacheBytes(legacyKey, byteArrayOf(9, 9, 9, 9))
        cacheBytes(unversionedKey, byteArrayOf(8, 8, 8, 8))
        cacheBytes(CacheIdentity.cacheKey(source.cacheIdentity, "old-partial"), byteArrayOf(7), contentLength = 100)
        MediaCache.teardown()
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val cache = assertNotNull(MediaCache.activeCache())
        val manager = ExoPlayerManager(context, { _, _, _ -> }, { _, _ -> }, { _ -> }, { _ -> }, { _ -> })
        fun offlineRead(): ByteArray {
            val dataSource = CacheDataSource.Factory()
                .setCache(cache)
                .setCacheKeyFactory { CacheIdentity.cacheKey(source, it.uri.toString()) }
                .createDataSource()
            try {
                assertEquals(4L, dataSource.open(DataSpec.Builder().setUri(source.uri).build()))
                val result = ByteArray(4)
                var offset = 0
                while (offset < result.size) {
                    val count = dataSource.read(result, offset, result.size - offset)
                    assertTrue(count > 0)
                    offset += count
                }
                assertEquals(-1, dataSource.read(ByteArray(1), 0, 1))
                return result
            } finally {
                dataSource.close()
            }
        }
        try {
            manager.setSources(listOf(source))
            val snapshot = assertNotNull(manager.cacheStatusSnapshot(source.id))
            assertEquals(rootKey, snapshot.rootCacheKey)
            val absent = manager.cacheStatus(source.id, snapshot)
            assertFalse(absent.isComplete)
            assertEquals(0L, absent.cachedBytes)
            assertEquals(0L, absent.totalBytes)
            assertFailsWith<IOException> { offlineRead() }
            assertTrue(cache.isCached(legacyKey, 0, 4))
            assertTrue(cache.isCached(unversionedKey, 0, 4))

            cacheBytes(rootKey, expected)
            val complete = manager.cacheStatus(source.id, snapshot)
            assertTrue(complete.isComplete)
            assertEquals(4L, complete.cachedBytes)
            assertEquals(4L, complete.totalBytes)
            assertTrue(expected.contentEquals(offlineRead()))
            assertTrue(cache.isCached(legacyKey, 0, 4))
        } finally {
            manager.disposeAll()
        }
    }

    @Test
    fun cacheStatus_progressiveRequiresKnownLengthAndExactCoverage_notByteSum() {
        MediaCache.configure(context, true, 1024L * 1024, Runnable::run)
        val manager = ExoPlayerManager(context, { _, _, _ -> }, { _, _ -> }, { _ -> }, { _ -> }, { _ -> })
        try {
            for (stableKey in listOf("coverage", null)) {
                val source = source().copy(cacheKey = stableKey)
                val key = CacheIdentity.cacheKey(source, source.uri)
                manager.setSources(listOf(source))
                val snapshot = assertNotNull(manager.cacheStatusSnapshot(source.id))
                cacheBytes(key, byteArrayOf(1, 2), contentLength = -1)
                assertFalse(manager.cacheStatus(source.id, snapshot).isComplete)
                cacheBytes(key, byteArrayOf(5, 6), position = 4, contentLength = 4)
                val gap = manager.cacheStatus(source.id, snapshot)
                assertEquals(4L, gap.cachedBytes)
                assertEquals(4L, gap.totalBytes)
                assertFalse(gap.isComplete)
                cacheBytes(key, byteArrayOf(3, 4), position = 2, contentLength = 4)
                assertTrue(manager.cacheStatus(source.id, snapshot).isComplete)
            }
        } finally {
            manager.disposeAll()
        }
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
