import 'dart:async';

import 'package:native_feed_player/native_feed_player.dart';
import 'package:native_feed_player/native_feed_player_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// In-memory [FeedPlayerPlatform] for unit tests.
class RecordingFeedPlayerPlatform
    with MockPlatformInterfaceMixin
    implements FeedPlayerPlatform {
  final StreamController<ControllerReleaseEvent> _releases =
      StreamController<ControllerReleaseEvent>.broadcast();
  final Map<int, StreamController<VideoMetrics>> _metrics =
      <int, StreamController<VideoMetrics>>{};
  final Map<int, StreamController<VideoSize>> _videoSizes =
      <int, StreamController<VideoSize>>{};
  final Map<int, StreamController<PlaybackStatusUpdate>> _states =
      <int, StreamController<PlaybackStatusUpdate>>{};

  final List<int> attachedTextureControllerIds = <int>[];
  final List<int> detachedTextureControllerIds = <int>[];
  final List<int> attachedViewControllerIds = <int>[];
  final List<int> detachedViewControllerIds = <int>[];
  final List<int> disposedControllerIds = <int>[];
  final List<String> visibleSourceIds = <String>[];
  final List<String> attachmentOperations = <String>[];

  Completer<int>? nextAttachTexture;
  Completer<void>? nextDetachTexture;
  Object? attachTextureError;
  FeedPlayerConfig? initializedWith;
  int nextControllerId = 1;

  Future<void> close() async {
    unawaited(_releases.close());
    for (final StreamController<VideoMetrics> c in _metrics.values) {
      unawaited(c.close());
    }
    for (final StreamController<VideoSize> c in _videoSizes.values) {
      unawaited(c.close());
    }
    for (final StreamController<PlaybackStatusUpdate> c in _states.values) {
      unawaited(c.close());
    }
  }

  void emitRelease({
    required int controllerId,
    required ControllerReleaseReason reason,
  }) {
    _releases.add(
      ControllerReleaseEvent(controllerId: controllerId, reason: reason),
    );
  }

  void emitMetrics({
    required int controllerId,
    int rebufferCount = 0,
    int droppedFrames = 0,
    int? firstFrameLatencyMs,
  }) {
    _metricsControllerFor(controllerId).add(
      VideoMetrics(
        controllerId: controllerId,
        rebufferCount: rebufferCount,
        droppedFrames: droppedFrames,
        firstFrameLatency: firstFrameLatencyMs == null
            ? null
            : Duration(milliseconds: firstFrameLatencyMs),
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
  }

  void emitVideoSize({
    required int controllerId,
    required int width,
    required int height,
    int rotationDegrees = 0,
  }) {
    _videoSizeControllerFor(controllerId).add(
      VideoSize(width: width, height: height, rotationDegrees: rotationDegrees),
    );
  }

  void emitState({
    required int controllerId,
    required VideoPlaybackState state,
    PlaybackError? error,
  }) {
    _stateControllerFor(
      controllerId,
    ).add(PlaybackStatusUpdate(state: state, error: error));
  }

  StreamController<VideoMetrics> _metricsControllerFor(int id) => _metrics
      .putIfAbsent(id, () => StreamController<VideoMetrics>.broadcast());

  StreamController<VideoSize> _videoSizeControllerFor(int id) => _videoSizes
      .putIfAbsent(id, () => StreamController<VideoSize>.broadcast());

  StreamController<PlaybackStatusUpdate> _stateControllerFor(int id) =>
      _states.putIfAbsent(
        id,
        () => StreamController<PlaybackStatusUpdate>.broadcast(),
      );

  @override
  Stream<ControllerReleaseEvent> get releaseEvents => _releases.stream;

  @override
  Future<void> initialize(FeedPlayerConfig config) async {
    initializedWith = config;
  }

  @override
  Future<void> setSources(List<FeedSource> sources) async {}

  @override
  Future<void> appendSources(
    List<FeedSource> sources, {
    required int rankOffset,
  }) async {}

  @override
  Future<void> removeSources(List<String> sourceIds) async {}

  @override
  Future<int> createController({
    required String sourceId,
    required bool autoPlay,
    required bool looping,
  }) async {
    return nextControllerId++;
  }

  @override
  Future<void> disposeController(int controllerId) async {
    disposedControllerIds.add(controllerId);
  }

  @override
  Future<void> play(int controllerId) async {}

  @override
  Future<void> pause(int controllerId) async {}

  @override
  Future<void> seekTo(int controllerId, Duration position) async {}

  @override
  Future<void> setVolume(int controllerId, double volume) async {}

  @override
  Future<void> setMuted(int controllerId, bool muted) async {}

  @override
  Future<void> setPlaybackSpeed(int controllerId, double speed) async {}

  @override
  Future<void> setLooping(int controllerId, bool looping) async {}

  @override
  Future<void> setAudioPolicy(AudioPolicy policy) async {}

  @override
  Stream<PlaybackPosition> positionStream(int controllerId) =>
      const Stream<PlaybackPosition>.empty();

  @override
  Stream<PlaybackStatusUpdate> stateStream(int controllerId) =>
      _stateControllerFor(controllerId).stream;

  @override
  Stream<VideoMetrics> metricsStream(int controllerId) =>
      _metricsControllerFor(controllerId).stream;

  @override
  Stream<VideoSize> videoSizeStream(int controllerId) =>
      _videoSizeControllerFor(controllerId).stream;

  @override
  Future<void> setVisibleSource(String sourceId) async {
    visibleSourceIds.add(sourceId);
  }

  @override
  Future<void> evictCachedMedia(List<String> sourceIds) async {}

  @override
  Future<void> clearMediaCache() async {}

  @override
  Future<CacheStatus> cacheStatus(String sourceId) async => CacheStatus(
    sourceId: sourceId,
    cachedBytes: 0,
    totalBytes: 0,
    isComplete: false,
  );

  @override
  Future<int> cacheUsageBytes() async => 0;

  @override
  Future<void> attachView({
    required int controllerId,
    required int viewId,
  }) async {
    attachedViewControllerIds.add(controllerId);
    attachmentOperations.add('attachView:$controllerId:$viewId');
  }

  @override
  Future<void> detachView({required int controllerId}) async {
    detachedViewControllerIds.add(controllerId);
    attachmentOperations.add('detachView:$controllerId');
  }

  @override
  Future<int> attachTexture(int controllerId) async {
    attachedTextureControllerIds.add(controllerId);
    attachmentOperations.add('attachTexture:$controllerId');
    final Object? error = attachTextureError;
    if (error != null) {
      throw error;
    }
    final Completer<int>? gate = nextAttachTexture;
    nextAttachTexture = null;
    if (gate != null) {
      return gate.future;
    }
    return 1000 + controllerId;
  }

  @override
  Future<void> detachTexture(int controllerId) async {
    detachedTextureControllerIds.add(controllerId);
    attachmentOperations.add('detachTexture:$controllerId');
    final Completer<void>? gate = nextDetachTexture;
    nextDetachTexture = null;
    await gate?.future;
  }

  @override
  Future<void> dispose() async {}
}
