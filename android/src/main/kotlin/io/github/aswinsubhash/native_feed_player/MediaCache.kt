package io.github.aswinsubhash.native_feed_player

import android.content.Context
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import java.util.TreeMap
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Credential-safe identity shared by preloading and persistent cache operations. */
internal object CacheIdentity {
    private const val SCHEMA_VERSION = "v2"
    const val CACHE_KEY_PREFIX = "native-feed-player:$SCHEMA_VERSION:"

    fun forSource(uri: String, headers: Map<String, String>, cacheKey: String? = null): String {
        val canonicalHeaders = normalizedHeaders(headers).entries
            .joinToString(separator = "") { (name, value) ->
                "${name.length}:$name${value.length}:$value"
            }
        // A caller-supplied cacheKey replaces the URI so signed or expiring
        // URLs share one entry; headers stay in the digest either way.
        val identity = cacheKey?.takeIf { it.isNotBlank() } ?: uri
        return CACHE_KEY_PREFIX + sha256("$SCHEMA_VERSION\n${identity.length}:$identity\n$canonicalHeaders")
    }

    fun normalizedHeaders(headers: Map<String, String>): Map<String, String> {
        val result = sortedMapOf<String, String>()
        headers.entries
            .sortedWith(
                compareBy<Map.Entry<String, String>>(
                    { it.key.trim().lowercase(Locale.ROOT) },
                    { it.key }
                )
            )
            .forEach { entry ->
                val name = entry.key.trim().lowercase(Locale.ROOT)
                if (name.isNotEmpty()) {
                    result[name] = entry.value.trim()
                }
            }
        return result
    }

    fun cacheKey(sourceIdentity: String, requestUri: String): String =
        "$sourceIdentity/${sha256(requestUri)}"

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(Locale.ROOT, byte.toInt() and 0xff) }
}

internal val RegisteredSource.cacheIdentity: String
    get() = CacheIdentity.forSource(uri, headers, cacheKey)

internal fun RegisteredSource.mediaItem(): MediaItem {
    val builder = MediaItem.Builder().setUri(uri)
    if (kind == FeedMediaKindMessage.HLS) {
        builder.setMimeType(MimeTypes.APPLICATION_M3U8)
    }
    return builder.build()
}

/**
 * Process-wide media cache.
 *
 * [SimpleCache] exclusively locks its directory, so only one instance may
 * exist. Construction and index scans run on a background [Executor] because
 * they touch disk; consumers either await [awaitCache] from a loader thread or
 * observe [isReady]. Engine attachment is reference-counted with [retain] and
 * [release] so concurrent Flutter engines share one live instance instead of
 * fighting over the directory lock.
 */
@OptIn(UnstableApi::class)
internal object MediaCache {
    private const val TAG = "NativeFeedPlayer"
    private const val CACHE_DIRECTORY = "native_feed_player"

    /** Upper bound on how long a loader thread waits for the cache to open. */
    private const val CACHE_READY_TIMEOUT_MS = 2_000L

    private var cache: SimpleCache? = null
    private var databaseProvider: StandaloneDatabaseProvider? = null
    private var configuredMaxBytes: Long = 0
    private val cacheKeysBySource = mutableMapOf<String, MutableSet<String>>()

    /** Completes once the current configure attempt finishes (null = no cache). */
    @Volatile
    private var readiness: CompletableFuture<SimpleCache?> =
        CompletableFuture.completedFuture(null)

    /** Discards results of configure attempts superseded by newer calls. */
    private var configureGeneration = 0

    /** Live engine count; the cache is torn down when it reaches zero. */
    private var refCount = 0

    @Synchronized
    fun retain() {
        refCount += 1
    }

    /** Drops one engine reference; tears the cache down at zero. */
    @Synchronized
    fun release() {
        refCount = (refCount - 1).coerceAtLeast(0)
        if (refCount == 0) {
            teardown()
        }
    }

    /**
     * Configures the cache. Disk work runs on [executor]; the call returns
     * immediately and playback degrades to uncached until [isReady].
     */
    @Synchronized
    fun configure(context: Context, enabled: Boolean, maxBytes: Long, executor: Executor) {
        if (!enabled) {
            teardown()
            return
        }
        if (cache != null && configuredMaxBytes == maxBytes) {
            return
        }
        // Another engine still plays through the live cache; re-creating it
        // under them would break their reads, so adopt the new budget only.
        if (cache != null && refCount > 1) {
            if (configuredMaxBytes != maxBytes) {
                Log.w(
                    TAG,
                    "MediaCache budget change to $maxBytes bytes ignored while " +
                        "another engine is attached; reconfigure after detach."
                )
                configuredMaxBytes = maxBytes
            }
            return
        }

        teardown()
        val generation = ++configureGeneration
        val future = CompletableFuture<SimpleCache?>()
        readiness = future
        executor.execute {
            val appContext = context.applicationContext
            val provider = StandaloneDatabaseProvider(appContext)
            var created: SimpleCache? = null
            try {
                created = SimpleCache(
                    File(appContext.cacheDir, CACHE_DIRECTORY),
                    LeastRecentlyUsedCacheEvictor(maxBytes),
                    provider
                )
                synchronized(this@MediaCache) {
                    if (generation == configureGeneration) {
                        databaseProvider = provider
                        configuredMaxBytes = maxBytes
                        cache = created
                        invalidateLegacyCacheKeys()
                        rebuildSourceKeyGroups()
                    }
                }
                if (generation == configureGeneration) {
                    future.complete(created)
                } else {
                    runCatching { created.release() }
                    runCatching { provider.close() }
                    future.complete(null)
                }
            } catch (error: Throwable) {
                synchronized(this@MediaCache) {
                    if (generation == configureGeneration) {
                        runCatching { created?.release() }
                        cache = null
                        databaseProvider = null
                        configuredMaxBytes = 0
                        cacheKeysBySource.clear()
                    }
                }
                runCatching { provider.close() }
                Log.w(TAG, "MediaCache failed to open; playing uncached.", error)
                future.complete(null)
            }
        }
    }

    /** True when a configure attempt has finished and a cache is live. */
    val isReady: Boolean
        @Synchronized get() = cache != null && readiness.isDone

    /**
     * Blocks the calling (loader) thread until the cache is ready. Returns the
     * live cache, or null when it is disabled, still opening past [timeoutMs],
     * or failed to open.
     */
    fun awaitCache(timeoutMs: Long = CACHE_READY_TIMEOUT_MS): SimpleCache? = try {
        readiness.get(timeoutMs, TimeUnit.MILLISECONDS)
    } catch (error: TimeoutException) {
        null
    } catch (error: ExecutionException) {
        null
    } catch (error: InterruptedException) {
        Thread.currentThread().interrupt()
        null
    }

    @Synchronized
    fun isEnabled(): Boolean = cache != null

    /** Returns the active cache instance. */
    @Synchronized
    fun activeCache(): SimpleCache? = cache

    @Synchronized
    fun usageBytes(): Long = cache?.cacheSpace ?: 0L

    /** Cached bytes across the manifest/media and all child requests for [sourceIdentity]. */
    @Synchronized
    fun cachedBytes(sourceIdentity: String): Long {
        val activeCache = cache ?: return 0L
        return keysForSource(activeCache, sourceIdentity).sumOf { key ->
            activeCache.getCachedBytes(key, 0, Long.MAX_VALUE)
        }
    }

    /** Sum of known child content lengths, or 0 while lengths are unresolved. */
    @Synchronized
    fun contentLength(sourceIdentity: String): Long {
        val activeCache = cache ?: return 0L
        return keysForSource(activeCache, sourceIdentity).sumOf { key ->
            ContentMetadata.getContentLength(activeCache.getContentMetadata(key)).coerceAtLeast(0L)
        }
    }

    @Synchronized
    fun evict(sourceIdentity: String) {
        val activeCache = cache ?: return
        for (key in keysForSource(activeCache, sourceIdentity)) {
            removeKey(activeCache, key)
        }
        cacheKeysBySource.remove(sourceIdentity)
    }

    @Synchronized
    fun evictAll() {
        val activeCache = cache ?: return
        for (key in activeCache.keys.toList()) {
            removeKey(activeCache, key)
        }
        cacheKeysBySource.clear()
    }

    /** Tears the cache down regardless of the reference count. */
    @Synchronized
    fun teardown() {
        configureGeneration += 1
        runCatching { cache?.release() }
        cache = null
        runCatching { databaseProvider?.close() }
        databaseProvider = null
        configuredMaxBytes = 0
        cacheKeysBySource.clear()
        readiness = CompletableFuture.completedFuture(null)
    }

    @VisibleForTesting
    @Synchronized
    internal fun resetForTesting() {
        refCount = 0
        teardown()
    }

    /** Builds a source-specific chain so HLS manifests, keys, and segments inherit headers. */
    fun createDataSourceFactory(source: RegisteredSource): DataSource.Factory {
        // Resolving the cache is deferred to data-source creation, which runs
        // on ExoPlayer's loader thread, so configure() never blocks the main
        // thread and an in-flight open only delays the first read.
        return DataSource.Factory { buildDataSourceFactory(source).createDataSource() }
    }

    private fun buildDataSourceFactory(source: RegisteredSource): DataSource.Factory {
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(false)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(15_000)

        val normalizedHeaders = CacheIdentity.normalizedHeaders(source.headers)
        val resolving = ResolvingDataSource.Factory(http) { dataSpec: DataSpec ->
            resolveDataSpec(dataSpec, normalizedHeaders)
        }

        val activeCache = awaitCache()
        if (activeCache == null) {
            return resolving
        }
        val sourceIdentity = source.cacheIdentity
        return CacheDataSource.Factory()
            .setCache(activeCache)
            .setUpstreamDataSourceFactory(resolving)
            .setCacheKeyFactory { dataSpec ->
                CacheIdentity.cacheKey(sourceIdentity, dataSpec.uri.toString()).also { key ->
                    registerCacheKey(sourceIdentity, key)
                }
            }
            // Preserve cached reads after upstream failures.
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    fun createMediaSource(source: RegisteredSource): MediaSource =
        DefaultMediaSourceFactory(createDataSourceFactory(source))
            .createMediaSource(source.mediaItem())

    internal fun resolveDataSpec(
        dataSpec: DataSpec,
        sourceHeaders: Map<String, String>
    ): DataSpec = if (sourceHeaders.isEmpty()) {
        dataSpec
    } else {
        dataSpec.withRequestHeaders(mergeRequestHeaders(dataSpec.httpRequestHeaders, sourceHeaders))
    }

    internal fun mergeRequestHeaders(
        requestHeaders: Map<String, String>,
        sourceHeaders: Map<String, String>
    ): TreeMap<String, String> = TreeMap<String, String>(String.CASE_INSENSITIVE_ORDER).apply {
        putAll(requestHeaders)
        putAll(sourceHeaders)
    }

    @Synchronized
    private fun registerCacheKey(sourceIdentity: String, key: String) {
        cacheKeysBySource.getOrPut(sourceIdentity) { mutableSetOf() }.add(key)
    }

    private fun keysForSource(activeCache: SimpleCache, sourceIdentity: String): Set<String> {
        val prefix = "$sourceIdentity/"
        val persisted = activeCache.keys.filterTo(mutableSetOf()) { it.startsWith(prefix) }
        cacheKeysBySource[sourceIdentity]?.let { persisted.addAll(it) }
        return persisted
    }

    private fun removeKey(activeCache: SimpleCache, key: String) {
        runCatching { activeCache.removeResource(key) }
    }

    private fun invalidateLegacyCacheKeys() {
        val activeCache = cache ?: return
        for (key in activeCache.keys.toList()) {
            if (!key.startsWith(CacheIdentity.CACHE_KEY_PREFIX)) {
                removeKey(activeCache, key)
            }
        }
    }

    private fun rebuildSourceKeyGroups() {
        val activeCache = cache ?: return
        cacheKeysBySource.clear()
        for (key in activeCache.keys) {
            val sourceIdentity = key.substringBefore('/', missingDelimiterValue = "")
            if (sourceIdentity.startsWith(CacheIdentity.CACHE_KEY_PREFIX)) {
                registerCacheKey(sourceIdentity, key)
            }
        }
    }
}
