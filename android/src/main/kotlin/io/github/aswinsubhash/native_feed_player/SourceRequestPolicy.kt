package io.github.aswinsubhash.native_feed_player

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Decides which network destinations may receive a source's headers.
 *
 * Headers reach the source URL's own origin and explicitly trusted HTTPS
 * origins only. Every other destination — cross-origin HLS children and
 * redirect targets included — receives none of them.
 */
internal class SourceRequestPolicy(
    sourceUri: String,
    headers: Map<String, String>,
    trustedOrigins: Collection<String>
) {
    private data class Origin(val scheme: String, val host: String, val port: Int)

    /** Source headers to apply; Range stays under Media3's control. */
    val headers: Map<String, String> =
        CacheIdentity.normalizedHeaders(headers).filterKeys { it != "range" }

    private val sourceOrigin = sourceUri.toHttpUrlOrNull()?.origin()
    private val trusted: Set<Origin> = trustedOrigins
        .mapNotNull { it.toHttpUrlOrNull()?.takeIf(HttpUrl::isHttps)?.origin() }
        .toSet()

    fun allowsHeaders(url: HttpUrl): Boolean {
        val origin = url.origin()
        return origin == sourceOrigin || (url.isHttps && origin in trusted)
    }

    private fun HttpUrl.origin() = Origin(scheme, host, port)

    companion object {
        /** Canonical `scheme://host[:port]` form, or null when not an HTTP(S) origin. */
        fun canonicalOrigin(value: String): String? {
            val url = value.trim().toHttpUrlOrNull() ?: return null
            val host = if (url.host.contains(':')) "[${url.host}]" else url.host
            val defaultPort = HttpUrl.defaultPort(url.scheme)
            return "${url.scheme}://$host${if (url.port == defaultPort) "" else ":${url.port}"}"
        }
    }
}

/**
 * Network interceptor: runs once per network hop, so redirect targets are
 * evaluated individually instead of inheriting the first request's headers.
 */
internal class SourceHeaderInterceptor(private val policy: SourceRequestPolicy) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val builder = request.newBuilder()
        for (name in policy.headers.keys) {
            builder.removeHeader(name)
        }
        if (policy.allowsHeaders(request.url)) {
            for ((name, value) in policy.headers) {
                builder.header(name, value)
            }
        }
        return chain.proceed(builder.build())
    }
}
