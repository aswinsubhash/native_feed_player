import 'messages.g.dart';

/// Playback quality counters for one controller.
///
/// Both platforms report the same definitions:
///
/// * [firstFrameLatency] is measured from controller creation to the first
///   frame actually rendered to a surface.
/// * [droppedFrames] and [rebufferCount] are monotonic totals for the
///   controller's lifetime, not deltas between samples.
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

  /// Video frames the decoder or renderer dropped, lifetime total.
  final int droppedFrames;

  /// Creation to first rendered frame. Null until the first frame appears.
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

/// Playback position, plus buffer and duration when the platform knows them.
class PlaybackPosition {
  const PlaybackPosition({
    required this.position,
    this.bufferedPosition,
    this.duration,
  });

  final Duration position;

  /// How far ahead of [position] media is buffered.
  final Duration? bufferedPosition;

  /// Total duration, or null for live/unknown-length media.
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
