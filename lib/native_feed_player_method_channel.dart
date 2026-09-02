import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_feed_player_platform_interface.dart';
import 'src/controller_release.dart';
import 'src/feed_player_config.dart';
import 'src/feed_player_exception.dart';
import 'src/feed_source.dart';
import 'src/messages.g.dart';
import 'src/playback_error.dart';
import 'src/video_metrics.dart';
import 'src/video_playback_state.dart';
import 'src/video_size.dart';

/// Pigeon implementation of [FeedPlayerPlatform].
class MethodChannelFeedPlayer extends FeedPlayerPlatform {
  MethodChannelFeedPlayer({
    NativeFeedPlayerHostApi? hostApi,
    Stream<PlaybackStateEvent>? playbackStateEventStream,
    Stream<PositionEvent>? positionEventStream,
    Stream<MetricsEvent>? metricsEventStream,
    Stream<VideoSizeEvent>? videoSizeEventStream,
    Stream<ControllerLifecycleEvent>? lifecycleEventStream,
  }) : hostApi = hostApi ?? NativeFeedPlayerHostApi(),
       _playbackStateEventStream = playbackStateEventStream,
       _positionEventStream = positionEventStream,
       _metricsEventStream = metricsEventStream,
       _videoSizeEventStream = videoSizeEventStream,
       _lifecycleEventStream = lifecycleEventStream;

  @visibleForTesting
  final NativeFeedPlayerHostApi hostApi;

  final Stream<PlaybackStateEvent>? _playbackStateEventStream;
  final Stream<PositionEvent>? _positionEventStream;
  final Stream<MetricsEvent>? _metricsEventStream;
  final Stream<VideoSizeEvent>? _videoSizeEventStream;
  final Stream<ControllerLifecycleEvent>? _lifecycleEventStream;

  late final Stream<PlaybackStateEvent> _states =
      (_playbackStateEventStream ?? playbackStateEvents())
          .map(_cachePlaybackState)
          .asBroadcastStream();

  late final Stream<PositionEvent> _positions =
      (_positionEventStream ?? positionEvents())
          .map(_cachePosition)
          .asBroadcastStream();

  late final Stream<MetricsEvent> _metrics =
      (_metricsEventStream ?? metricsEvents())
          .map(_cacheMetrics)
          .asBroadcastStream();

  late final Stream<VideoSizeEvent> _videoSizes =
      (_videoSizeEventStream ?? videoSizeEvents())
          .map(_cacheVideoSize)
          .asBroadcastStream();

  late final Stream<ControllerLifecycleEvent> _lifecycle =
      (_lifecycleEventStream ?? lifecycleEvents()).asBroadcastStream();

  final Map<int, Stream<PlaybackStatusUpdate>> _stateStreams =
      <int, Stream<PlaybackStatusUpdate>>{};
  final Map<int, Stream<PlaybackPosition>> _positionStreams =
      <int, Stream<PlaybackPosition>>{};
  final Map<int, Stream<VideoMetrics>> _metricsStreams =
      <int, Stream<VideoMetrics>>{};
  final Map<int, Stream<VideoSize>> _videoSizeStreams =
      <int, Stream<VideoSize>>{};
  final Map<int, PlaybackStatusUpdate> _latestStates =
      <int, PlaybackStatusUpdate>{};
  final Map<int, VideoMetrics> _latestMetrics = <int, VideoMetrics>{};
  final Map<int, VideoSize> _latestVideoSizes = <int, VideoSize>{};
  final Map<int, PlaybackPosition> _latestPositions = <int, PlaybackPosition>{};
  StreamSubscription<PlaybackStateEvent>? _stateCacheSubscription;
  StreamSubscription<MetricsEvent>? _metricsCacheSubscription;
  StreamSubscription<VideoSizeEvent>? _videoSizeCacheSubscription;
  StreamSubscription<PositionEvent>? _positionCacheSubscription;
  StreamSubscription<ControllerLifecycleEvent>? _lifecycleCacheSubscription;

  /// Subscribes the per-controller cache cleaner to [_lifecycle]. Called from
  /// the [releaseEvents] initializer so it is always the *first* listener on
  /// the broadcast stream — caches must be forgotten before any downstream
  /// release handler runs — and from [initialize] as a fallback for callers
  /// that never listen to [releaseEvents].
  void _ensureLifecycleCache() {
    _lifecycleCacheSubscription ??= _lifecycle.listen(
      (ControllerLifecycleEvent event) => _forgetStreams(event.controllerId),
      onError: _reportCacheStreamError,
    );
  }

  @override
  late final Stream<ControllerReleaseEvent> releaseEvents = () {
    _ensureLifecycleCache();
    return _lifecycle
        .map(
          (ControllerLifecycleEvent event) => ControllerReleaseEvent(
            controllerId: event.controllerId,
            reason: releaseReasonFromMessage(event.reason),
          ),
        )
        .asBroadcastStream();
  }();

  @override
  Future<void> initialize(FeedPlayerConfig config) async {
    _ensureSupportedPlatform();
    _latestStates.clear();
    _latestMetrics.clear();
    _latestVideoSizes.clear();
    _latestPositions.clear();
    _stateCacheSubscription ??= _states.listen(
      (_) {},
      onError: _reportCacheStreamError,
    );
    _metricsCacheSubscription ??= _metrics.listen(
      (_) {},
      onError: _reportCacheStreamError,
    );
    _videoSizeCacheSubscription ??= _videoSizes.listen(
      (_) {},
      onError: _reportCacheStreamError,
    );
    _ensureLifecycleCache();
    await hostApi.initialize(config.toMessage());
  }

  static void _reportCacheStreamError(Object error, StackTrace stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'native_feed_player',
        context: ErrorDescription('while caching native playback events'),
      ),
    );
  }

  @override
  Future<void> setSources(List<FeedSource> sources) async {
    await hostApi.setSources(_toMessages(sources));
  }

  @override
  Future<void> appendSources(
    List<FeedSource> sources, {
    required int rankOffset,
  }) async {
    await hostApi.appendSources(_toMessages(sources, startRank: rankOffset));
  }

  @override
  Future<void> removeSources(List<String> sourceIds) async {
    _validateIds(sourceIds);
    await hostApi.removeSources(SourceIdsRequest(sourceIds: sourceIds));
  }

  @override
  Future<int> createController({
    required String sourceId,
    required bool autoPlay,
    required bool looping,
  }) {
    _validateId(sourceId, 'sourceId');
    return hostApi.createController(
      CreateControllerRequest(
        sourceId: sourceId,
        autoPlay: autoPlay,
        looping: looping,
      ),
    );
  }

  @override
  Future<void> disposeController(int controllerId) async {
    await hostApi.disposeController(
      ControllerRequest(controllerId: controllerId),
    );
    _forgetStreams(controllerId);
  }

  @override
  Future<void> play(int controllerId) async {
    await hostApi.play(ControllerRequest(controllerId: controllerId));
  }

  @override
  Future<void> pause(int controllerId) async {
    await hostApi.pause(ControllerRequest(controllerId: controllerId));
  }

  @override
  Future<void> seekTo(int controllerId, Duration position) async {
    await hostApi.seekTo(
      SeekRequest(
        controllerId: controllerId,
        positionMs: position.inMilliseconds,
      ),
    );
  }

  @override
  Stream<PlaybackPosition> positionStream(int controllerId) {
    // The position channel is subscribed lazily: native only emits for
    // controllers that render or play, so subscribing on first use keeps the
    // channel silent until a UI actually wants positions. The latest value
    // is cached from then on, so every later subscriber replays it.
    _positionCacheSubscription ??= _positions.listen(
      (_) {},
      onError: _reportCacheStreamError,
    );
    return _positionStreams.putIfAbsent(controllerId, () {
      return Stream<PlaybackPosition>.multi((
        MultiStreamController<PlaybackPosition> output,
      ) {
        final PlaybackPosition? latest = _latestPositions[controllerId];
        if (latest != null) {
          output.addSync(latest);
        }
        final StreamSubscription<PositionEvent> subscription = _positions
            .where((PositionEvent event) => event.controllerId == controllerId)
            .listen(
              (PositionEvent event) =>
                  output.add(PlaybackPosition.fromMessage(event)),
              onError: output.addError,
              onDone: output.close,
            );
        output.onCancel = subscription.cancel;
      }, isBroadcast: true);
    });
  }

  @override
  Stream<PlaybackStatusUpdate> stateStream(int controllerId) {
    return _stateStreams.putIfAbsent(controllerId, () {
      return Stream<PlaybackStatusUpdate>.multi((
        MultiStreamController<PlaybackStatusUpdate> output,
      ) {
        final PlaybackStatusUpdate? latest = _latestStates[controllerId];
        if (latest != null) {
          output.addSync(latest);
        }
        final StreamSubscription<PlaybackStateEvent> subscription = _states
            .where(
              (PlaybackStateEvent event) => event.controllerId == controllerId,
            )
            .listen(
              (PlaybackStateEvent event) => output.add(_playbackUpdate(event)),
              onError: output.addError,
              onDone: output.close,
            );
        output.onCancel = subscription.cancel;
      }, isBroadcast: true);
    });
  }

  @override
  Stream<VideoMetrics> metricsStream(int controllerId) {
    return _metricsStreams.putIfAbsent(controllerId, () {
      return Stream<VideoMetrics>.multi((
        MultiStreamController<VideoMetrics> output,
      ) {
        final VideoMetrics? latest = _latestMetrics[controllerId];
        if (latest != null) {
          output.addSync(latest);
        }
        final StreamSubscription<MetricsEvent> subscription = _metrics
            .where((MetricsEvent event) => event.controllerId == controllerId)
            .listen(
              (MetricsEvent event) =>
                  output.add(VideoMetrics.fromMessage(event)),
              onError: output.addError,
              onDone: output.close,
            );
        output.onCancel = subscription.cancel;
      }, isBroadcast: true);
    });
  }

  @override
  Future<void> setVolume(int controllerId, double volume) async {
    if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Must be finite and within 0..1.',
      );
    }
    await hostApi.setVolume(
      ControllerDoubleRequest(controllerId: controllerId, value: volume),
    );
  }

  @override
  Future<void> setMuted(int controllerId, bool muted) async {
    await hostApi.setMuted(
      ControllerFlagRequest(controllerId: controllerId, value: muted),
    );
  }

  @override
  Future<void> setPlaybackSpeed(int controllerId, double speed) async {
    if (!speed.isFinite || speed <= 0.0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and positive.');
    }
    await hostApi.setPlaybackSpeed(
      ControllerDoubleRequest(controllerId: controllerId, value: speed),
    );
  }

  @override
  Future<void> setLooping(int controllerId, bool looping) async {
    await hostApi.setLooping(
      ControllerFlagRequest(controllerId: controllerId, value: looping),
    );
  }

  @override
  Future<void> setAudioPolicy(AudioPolicy policy) async {
    await hostApi.setAudioPolicy(policy.toMessage());
  }

  @override
  Stream<VideoSize> videoSizeStream(int controllerId) {
    return _videoSizeStreams.putIfAbsent(controllerId, () {
      return Stream<VideoSize>.multi((MultiStreamController<VideoSize> output) {
        final VideoSize? latest = _latestVideoSizes[controllerId];
        if (latest != null) {
          output.addSync(latest);
        }
        final StreamSubscription<VideoSizeEvent> subscription = _videoSizes
            .where((VideoSizeEvent event) => event.controllerId == controllerId)
            .listen(
              (VideoSizeEvent event) =>
                  output.add(VideoSize.fromMessage(event)),
              onError: output.addError,
              onDone: output.close,
            );
        output.onCancel = subscription.cancel;
      }, isBroadcast: true);
    });
  }

  @override
  Future<void> setVisibleSource(String sourceId) async {
    _validateId(sourceId, 'sourceId');
    await hostApi.setVisibleSource(VisibleSourceRequest(sourceId: sourceId));
  }

  @override
  Future<void> evictCachedMedia(List<String> sourceIds) async {
    _validateIds(sourceIds);
    await hostApi.evictCachedMedia(SourceIdsRequest(sourceIds: sourceIds));
  }

  @override
  Future<void> clearMediaCache() async {
    await hostApi.clearMediaCache();
  }

  @override
  Future<CacheStatus> cacheStatus(String sourceId) async {
    _validateId(sourceId, 'sourceId');
    final CacheStatusMessage message = await hostApi.cacheStatus(
      VisibleSourceRequest(sourceId: sourceId),
    );
    return CacheStatus.fromMessage(message);
  }

  @override
  Future<int> cacheUsageBytes() => hostApi.cacheUsageBytes();

  @override
  Future<void> attachView({
    required int controllerId,
    required int viewId,
  }) async {
    await hostApi.attachView(
      AttachViewRequest(controllerId: controllerId, viewId: viewId),
    );
  }

  @override
  Future<void> detachView({required int controllerId}) async {
    await hostApi.detachView(ControllerRequest(controllerId: controllerId));
  }

  @override
  Future<int> attachTexture(int controllerId) {
    return hostApi.attachTexture(ControllerRequest(controllerId: controllerId));
  }

  @override
  Future<void> detachTexture(int controllerId) async {
    await hostApi.detachTexture(ControllerRequest(controllerId: controllerId));
  }

  @override
  Future<void> dispose() async {
    await hostApi.disposeAll();
    await _stateCacheSubscription?.cancel();
    await _metricsCacheSubscription?.cancel();
    await _videoSizeCacheSubscription?.cancel();
    await _positionCacheSubscription?.cancel();
    await _lifecycleCacheSubscription?.cancel();
    _stateCacheSubscription = null;
    _metricsCacheSubscription = null;
    _videoSizeCacheSubscription = null;
    _positionCacheSubscription = null;
    _lifecycleCacheSubscription = null;
    _stateStreams.clear();
    _positionStreams.clear();
    _metricsStreams.clear();
    _videoSizeStreams.clear();
    _latestStates.clear();
    _latestMetrics.clear();
    _latestVideoSizes.clear();
    _latestPositions.clear();
  }

  MetricsEvent _cacheMetrics(MetricsEvent event) {
    _latestMetrics[event.controllerId] = VideoMetrics.fromMessage(event);
    return event;
  }

  PlaybackStateEvent _cachePlaybackState(PlaybackStateEvent event) {
    _latestStates[event.controllerId] = _playbackUpdate(event);
    return event;
  }

  PlaybackStatusUpdate _playbackUpdate(PlaybackStateEvent event) =>
      PlaybackStatusUpdate(
        state: playbackStateFromMessage(event.status),
        error: PlaybackError.fromMessage(event.error),
      );

  VideoSizeEvent _cacheVideoSize(VideoSizeEvent event) {
    _latestVideoSizes[event.controllerId] = VideoSize.fromMessage(event);
    return event;
  }

  PositionEvent _cachePosition(PositionEvent event) {
    _latestPositions[event.controllerId] = PlaybackPosition.fromMessage(event);
    return event;
  }

  List<FeedSourceMessage> _toMessages(
    List<FeedSource> sources, {
    int startRank = 0,
  }) {
    return <FeedSourceMessage>[
      for (int offset = 0; offset < sources.length; offset += 1)
        sources[offset].toMessage(startRank + offset),
    ];
  }

  void _forgetStreams(int controllerId) {
    _stateStreams.remove(controllerId);
    _positionStreams.remove(controllerId);
    _metricsStreams.remove(controllerId);
    _latestMetrics.remove(controllerId);
    _videoSizeStreams.remove(controllerId);
    _latestStates.remove(controllerId);
    _latestVideoSizes.remove(controllerId);
    _latestPositions.remove(controllerId);
  }

  void _validateIds(List<String> sourceIds) {
    for (final String sourceId in sourceIds) {
      _validateId(sourceId, 'sourceIds');
    }
  }

  void _validateId(String id, String name) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, name, 'Must not be empty.');
    }
  }

  void _ensureSupportedPlatform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        throw UnsupportedPlatformError(defaultTargetPlatform.name);
    }
  }
}
