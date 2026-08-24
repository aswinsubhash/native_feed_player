package io.github.aswinsubhash.native_feed_player

import androidx.media3.common.PlaybackException

/**
 * Translates Media3 failures into the plugin's platform-independent codes.
 *
 * Callers previously received a bare `error` state with no way to tell a
 * transient network drop from permanently malformed media, so retry logic was
 * impossible to write.
 */
internal object PlaybackErrorMapper {
    fun map(exception: PlaybackException): PlaybackErrorMessage {
        val code = codeFor(exception.errorCode)
        return PlaybackErrorMessage(
            code = code,
            message = exception.message ?: exception.errorCodeName,
            isRecoverable = isRecoverable(exception.errorCode),
            platformCode = exception.errorCodeName
        )
    }

    fun of(code: String, message: String, isRecoverable: Boolean): PlaybackErrorMessage =
        PlaybackErrorMessage(
            code = code,
            message = message,
            isRecoverable = isRecoverable,
            platformCode = null
        )

    private fun codeFor(errorCode: Int): String = when (errorCode) {
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_NO_PERMISSION,
        PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED -> "network_failed"

        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> "source_not_found"

        PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED -> "media_malformed"

        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> "decoder_failed"

        PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW -> "behind_live_window"

        else -> "playback_failed"
    }

    /**
     * Whether retrying the same source could plausibly succeed. Transport and
     * live-window problems are worth retrying; malformed or unsupported media
     * is not.
     */
    private fun isRecoverable(errorCode: Int): Boolean = when (errorCode) {
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW -> true

        else -> false
    }
}
