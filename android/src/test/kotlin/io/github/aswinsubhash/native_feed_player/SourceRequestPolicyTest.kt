package io.github.aswinsubhash.native_feed_player

import android.app.Application
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Asserts the headers each destination actually receives over real sockets,
 * covering HLS-style child requests and redirect chains.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
internal class SourceRequestPolicyTest {
    private val servers = mutableListOf<MockWebServer>()
    private val credentials = mapOf("Authorization" to "Bearer secret", "X-Api-Key" to "key-123")

    @After
    fun tearDown() {
        MediaCache.baseHttpClient = null
        servers.forEach { runCatching { it.shutdown() } }
    }

    private fun server(tls: HandshakeCertificates? = null): MockWebServer =
        MockWebServer().also { server ->
            tls?.let { server.useHttps(it.sslSocketFactory(), false) }
            server.start()
            servers += server
        }

    private fun source(uri: String, trusted: List<String> = emptyList()) = RegisteredSource(
        id = "a", uri = uri, rank = 0, kind = FeedMediaKindMessage.HLS,
        headers = credentials, trustedHeaderOrigins = trusted
    )

    /** Opens [url] the way an HLS child playlist, segment, or key load would. */
    private fun fetch(source: RegisteredSource, url: String, range: Boolean = false): Long {
        val dataSource = MediaCache.createDataSourceFactory(source, cacheEnabled = false).createDataSource()
        try {
            val spec = DataSpec.Builder().setUri(url).apply { if (range) setPosition(2).setLength(3) }.build()
            return dataSource.open(spec)
        } finally {
            dataSource.close()
        }
    }

    private fun MockWebServer.next(): RecordedRequest =
        assertNotNullRequest(takeRequest(5, TimeUnit.SECONDS))

    private fun assertNotNullRequest(request: RecordedRequest?): RecordedRequest =
        request ?: throw AssertionError("expected a request")

    private fun RecordedRequest.assertCredentials(present: Boolean) {
        assertEquals(if (present) "Bearer secret" else null, getHeader("Authorization"))
        assertEquals(if (present) "key-123" else null, getHeader("X-Api-Key"))
    }

    private fun ok() = MockResponse().setBody("segment")

    @Test
    fun childRequests_keepCredentialsOnTheSourceOrigin() {
        val origin = server()
        val foreign = server()
        repeat(2) { origin.enqueue(ok()) }
        foreign.enqueue(ok())
        val source = source(origin.url("/master.m3u8").toString())

        fetch(source, origin.url("/master.m3u8").toString())
        fetch(source, origin.url("/key.bin").toString())
        fetch(source, foreign.url("/segment.ts").toString())

        origin.next().assertCredentials(present = true)
        origin.next().assertCredentials(present = true)
        foreign.next().assertCredentials(present = false)
    }

    @Test
    fun redirects_areEvaluatedPerHop() {
        val origin = server()
        val foreign = server()
        origin.enqueue(MockResponse().setResponseCode(302).setHeader("Location", foreign.url("/hop").toString()))
        foreign.enqueue(MockResponse().setResponseCode(302).setHeader("Location", origin.url("/back").toString()))
        origin.enqueue(ok())
        val source = source(origin.url("/master.m3u8").toString())

        fetch(source, origin.url("/segment.ts").toString())

        origin.next().assertCredentials(present = true)
        foreign.next().assertCredentials(present = false)
        origin.next().assertCredentials(present = true)
    }

    @Test
    fun explicitlyTrustedHttpsOrigin_receivesCredentials_andOthersDoNot() {
        val certificate = HeldCertificate.Builder()
            .addSubjectAlternativeName("localhost")
            .addSubjectAlternativeName("127.0.0.1")
            .build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MediaCache.baseHttpClient = OkHttpClient.Builder()
            .sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager)
            .followSslRedirects(false)
            .build()
        val origin = server(serverTls)
        val cdn = server(serverTls)
        val untrusted = server(serverTls)
        origin.enqueue(MockResponse().setResponseCode(302).setHeader("Location", cdn.url("/seg.ts").toString()))
        cdn.enqueue(ok())
        untrusted.enqueue(ok())
        val cdnOrigin = cdn.url("/").toString().removeSuffix("/").uppercase()
        val source = source(origin.url("/master.m3u8").toString(), trusted = listOf(cdnOrigin))

        fetch(source, origin.url("/seg.ts").toString())
        fetch(source, untrusted.url("/seg.ts").toString())

        origin.next().assertCredentials(present = true)
        cdn.next().assertCredentials(present = true)
        untrusted.next().assertCredentials(present = false)
    }

    @Test
    fun trustedOrigin_neverAuthorizesPlainHttp() {
        val origin = server()
        val plain = server()
        plain.enqueue(ok())
        val plainOrigin = plain.url("/").toString().removeSuffix("/")
        val source = source("https://media.test/master.m3u8", trusted = listOf(plainOrigin))

        fetch(source, plain.url("/seg.ts").toString())

        plain.next().assertCredentials(present = false)
        assertEquals(0, origin.requestCount)
    }

    @Test
    fun protocolDowngradeRedirect_isNotFollowed() {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost")
            .addSubjectAlternativeName("127.0.0.1").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MediaCache.baseHttpClient = OkHttpClient.Builder()
            .sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager)
            .followSslRedirects(false)
            .build()
        val origin = server(serverTls)
        val plain = server()
        origin.enqueue(MockResponse().setResponseCode(302).setHeader("Location", plain.url("/seg.ts").toString()))
        val source = source(origin.url("/master.m3u8").toString())

        assertFailsWith<HttpDataSource.InvalidResponseCodeException> {
            fetch(source, origin.url("/seg.ts").toString())
        }
        origin.next().assertCredentials(present = true)
        assertEquals(0, plain.requestCount)
    }

    @Test
    fun sourceHeaders_cannotOverrideMediaRanges() {
        val origin = server()
        origin.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 2-4/7").setBody("gme"))
        val source = source(origin.url("/v.mp4").toString()).copy(
            headers = credentials + ("Range" to "bytes=0-")
        )

        fetch(source, origin.url("/v.mp4").toString(), range = true)

        val request = origin.next()
        request.assertCredentials(present = true)
        assertEquals("bytes=2-4", request.getHeader("Range"))
        assertNull(request.getHeader("Cookie"))
    }
}
