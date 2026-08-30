package io.github.aswinsubhash.native_feed_player

import android.content.Context
import androidx.annotation.OptIn
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

/** Credential-safe identity shared by preloading and persistent cache operations. */
internal object CacheIdentity {
    private const val SCHEMA_VERSION = "v2"
    const val CACHE_KEY_PREFIX = "native-feed-player:$SCHEMA_VERSION:"

    fun forSource(uri: String, headers: Map<String, String>): String {
        val canonicalHeaders = normalizedHeaders(headers).entries
            .joinToString(separator = "") { (name, value) ->
                "${name.length}:$name${value.length}:$value"
            }
        return CACHE_KEY_PREFIX + sha256("$SCHEMA_VERSION\n${uri.length}:$uri\n$canonicalHeaders")
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
    get() = CacheIdentity.forSource(uri, headers)

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
 * [SimpleCache] exclusively locks its directory, so only one instance may exist.
 */
@OptIn(UnstableApi::class)
internal object MediaCache {
    private const val CACHE_DIRECTORY = "native_feed_player"

    private var cache: SimpleCache? = null
    private var databaseProvider: StandaloneDatabaseProvider? = null
    private var configuredMaxBytes: Long = 0
    private val cacheKeysBySource = mutableMapOf<String, MutableSet<String>>()

    @Synchronized
    fun configure(context: Context, enabled: Boolean, maxBytes: Long) {
        if (!enabled) {
            release()
            return
        }
        if (cache != null && configuredMaxBytes == maxBytes) {
            return
        }

        release()
        val appContext = context.applicationContext
        val provider = StandaloneDatabaseProvider(appContext)
        try {
            val configuredCache = SimpleCache(
                File(appContext.cacheDir, CACHE_DIRECTORY),
                LeastRecentlyUsedCacheEvictor(maxBytes),
                provider
            )
            databaseProvider = provider
            configuredMaxBytes = maxBytes
            cache = configuredCache
            invalidateLegacyCacheKeys()
            rebuildSourceKeyGroups()
        } catch (error: Throwable) {
            runCatching { cache?.release() }
            cache = null
            databaseProvider = null
            runCatching { provider.close() }
            configuredMaxBytes = 0
            cacheKeysBySource.clear()
            throw error
        }
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

    @Synchronized
    fun release() {
        runCatching { cache?.release() }
        cache = null
        runCatching { databaseProvider?.close() }
        databaseProvider = null
        configuredMaxBytes = 0
        cacheKeysBySource.clear()
    }

    /** Builds a source-specific chain so HLS manifests, keys, and segments inherit headers. */
    @Synchronized
    fun createDataSourceFactory(source: RegisteredSource): DataSource.Factory {
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(false)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(15_000)

        val normalizedHeaders = CacheIdentity.normalizedHeaders(source.headers)
        val resolving = ResolvingDataSource.Factory(http) { dataSpec: DataSpec ->
            resolveDataSpec(dataSpec, normalizedHeaders)
        }

        val activeCache = cache ?: return resolving
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
    ): Map<String, String> = TreeMap<String, String>(String.CASE_INSENSITIVE_ORDER).apply {
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
