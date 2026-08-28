package io.github.aswinsubhash.native_feed_player

import android.content.Context
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/**
 * Process-wide media cache.
 *
 * [SimpleCache] exclusively locks its directory, so only one instance may exist.
 */
internal object MediaCache {
    private const val CACHE_DIRECTORY = "native_feed_player"

    private var cache: SimpleCache? = null
    private var databaseProvider: StandaloneDatabaseProvider? = null
    private var configuredMaxBytes: Long = 0

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
        databaseProvider = provider
        configuredMaxBytes = maxBytes
        cache = SimpleCache(
            File(appContext.cacheDir, CACHE_DIRECTORY),
            LeastRecentlyUsedCacheEvictor(maxBytes),
            provider
        )
    }

    @Synchronized
    fun isEnabled(): Boolean = cache != null

    /** Returns the active cache instance. */
    @Synchronized
    fun activeCache(): SimpleCache? = cache

    @Synchronized
    fun usageBytes(): Long = cache?.cacheSpace ?: 0L

    /** Cached bytes for [uri]. */
    @Synchronized
    fun cachedBytes(uri: String): Long {
        val activeCache = cache ?: return 0L
        return activeCache.getCachedBytes(uri, 0, Long.MAX_VALUE)
    }

    /** Total content length once known, or 0 while it is still unresolved. */
    @Synchronized
    fun contentLength(uri: String): Long {
        val activeCache = cache ?: return 0L
        val metadata = activeCache.getContentMetadata(uri)
        return androidx.media3.datasource.cache.ContentMetadata.getContentLength(metadata)
            .coerceAtLeast(0L)
    }

    @Synchronized
    fun evict(uri: String) {
        val activeCache = cache ?: return
        for (span in activeCache.getCachedSpans(uri)) {
            runCatching { activeCache.removeSpan(span) }
        }
    }

    @Synchronized
    fun evictAll() {
        val activeCache = cache ?: return
        for (key in activeCache.keys.toList()) {
            for (span in activeCache.getCachedSpans(key)) {
                runCatching { activeCache.removeSpan(span) }
            }
        }
    }

    @Synchronized
    fun release() {
        runCatching { cache?.release() }
        cache = null
        runCatching { databaseProvider?.close() }
        databaseProvider = null
        configuredMaxBytes = 0
    }

    /** Builds the shared cache and per-URI header data source chain. */
    @Synchronized
    fun createDataSourceFactory(
        headerLookup: (uri: String) -> Map<String, String>
    ): DataSource.Factory {
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(15_000)

        val resolving = ResolvingDataSource.Factory(http) { dataSpec: DataSpec ->
            val headers = headerLookup(dataSpec.uri.toString())
            if (headers.isEmpty()) dataSpec else dataSpec.withRequestHeaders(headers)
        }

        val activeCache = cache ?: return resolving

        return CacheDataSource.Factory()
            .setCache(activeCache)
            .setUpstreamDataSourceFactory(resolving)
            // Preserve cached reads after upstream failures.
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }
}
