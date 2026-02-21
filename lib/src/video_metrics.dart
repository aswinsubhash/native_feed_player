class VideoMetrics {
  const VideoMetrics({
    required this.controllerId,
    required this.rebufferCount,
    required this.droppedFramesEstimate,
    this.firstFrameLatency,
    this.timestamp,
  });

  final int controllerId;
  final int rebufferCount;
  final int droppedFramesEstimate;
  final Duration? firstFrameLatency;
  final DateTime? timestamp;

  factory VideoMetrics.fromEventMap(Map<dynamic, dynamic> map) {
    final int controllerId = _asInt(map['controllerId']);
    final int rebufferCount = _asInt(map['rebufferCount']);
    final int droppedFramesEstimate = _asInt(map['droppedFramesEstimate']);
    final int firstFrameLatencyMs = _asInt(map['firstFrameLatencyMs']);
    final int timestampMs = _asInt(map['timestampMs']);

    return VideoMetrics(
      controllerId: controllerId,
      rebufferCount: rebufferCount,
      droppedFramesEstimate: droppedFramesEstimate,
      firstFrameLatency: firstFrameLatencyMs > 0
          ? Duration(milliseconds: firstFrameLatencyMs)
          : null,
      timestamp: timestampMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(timestampMs)
          : null,
    );
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return 0;
  }
}
