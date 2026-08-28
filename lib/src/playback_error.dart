import 'messages.g.dart';

/// A native playback failure with recoverability and platform details.
class PlaybackError {
  const PlaybackError({
    required this.code,
    required this.message,
    required this.isRecoverable,
    this.platformCode,
  });

  /// Stable, platform-independent identifier such as `network_failed`,
  /// `source_not_found`, or `decoder_failed`.
  final String code;
  final String message;

  /// Whether retrying the source may succeed.
  final bool isRecoverable;

  /// Underlying platform error code, when one was available.
  final String? platformCode;

  static PlaybackError? fromMessage(PlaybackErrorMessage? message) {
    if (message == null) {
      return null;
    }
    return PlaybackError(
      code: message.code,
      message: message.message,
      isRecoverable: message.isRecoverable,
      platformCode: message.platformCode,
    );
  }

  @override
  String toString() =>
      'PlaybackError($code: $message, recoverable: $isRecoverable'
      '${platformCode == null ? '' : ', platform: $platformCode'})';
}

/// Bytes retained on disk for one source.
class CacheStatus {
  const CacheStatus({
    required this.sourceId,
    required this.cachedBytes,
    required this.totalBytes,
    required this.isComplete,
  });

  final String sourceId;
  final int cachedBytes;

  /// Total size when known, otherwise `0`.
  final int totalBytes;

  /// Whether the whole source is on disk and playable without network.
  final bool isComplete;

  double get fraction =>
      totalBytes <= 0 ? 0 : (cachedBytes / totalBytes).clamp(0.0, 1.0);

  static CacheStatus fromMessage(CacheStatusMessage message) => CacheStatus(
    sourceId: message.sourceId,
    cachedBytes: message.cachedBytes,
    totalBytes: message.totalBytes,
    isComplete: message.isComplete,
  );

  @override
  String toString() =>
      'CacheStatus($sourceId: $cachedBytes/$totalBytes, complete: $isComplete)';
}
