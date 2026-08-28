import 'messages.g.dart';

/// Playback quality metrics for one controller.
///
/// [firstFrameLatency] spans creation to the first rendered frame.
/// [droppedFrames] and [rebufferCount] are lifetime totals.
class VideoMetrics {
  const VideoMetrics({
    required this.controllerId,
    required this.rebufferCount,
    required this.droppedFrames,
    required this.timestamp,
    this.firstFrameLatency,
  });

  final int controllerId;

  /// Times playback stalled after having become ready at least once.
  final int rebufferCount;

  /// Lifetime count of dropped video frames.
  final int droppedFrames;

  /// Time from controller creation to the first rendered frame.
  final Duration? firstFrameLatency;

  final DateTime timestamp;

  static VideoMetrics fromMessage(MetricsEvent event) {
    final int? latencyMs = event.firstFrameLatencyMs;
    return VideoMetrics(
      controllerId: event.controllerId,
      rebufferCount: event.rebufferCount,
      droppedFrames: event.droppedFrames,
      firstFrameLatency: latencyMs == null
          ? null
          : Duration(milliseconds: latencyMs),
      timestamp: DateTime.fromMillisecondsSinceEpoch(event.timestampMs),
    );
  }

  @override
  String toString() =>
      'VideoMetrics(controller: $controllerId, rebuffers: $rebufferCount, '
      'dropped: $droppedFrames, firstFrame: $firstFrameLatency)';
}

/// Playback position, buffered position, and duration.
class PlaybackPosition {
  const PlaybackPosition({
    required this.position,
    this.bufferedPosition,
    this.duration,
  });

  final Duration position;

  /// How far ahead of [position] media is buffered.
  final Duration? bufferedPosition;

  /// Total duration, or `null` for live or unknown-length media.
  final Duration? duration;

  static PlaybackPosition fromMessage(PositionEvent event) {
    final int? bufferedMs = event.bufferedPositionMs;
    final int? durationMs = event.durationMs;
    return PlaybackPosition(
      position: Duration(milliseconds: event.positionMs),
      bufferedPosition: bufferedMs == null
          ? null
          : Duration(milliseconds: bufferedMs),
      duration: durationMs == null || durationMs <= 0
          ? null
          : Duration(milliseconds: durationMs),
    );
  }

  @override
  String toString() =>
      'PlaybackPosition($position of ${duration ?? 'unknown'}, '
      'buffered: ${bufferedPosition ?? 'unknown'})';
}
