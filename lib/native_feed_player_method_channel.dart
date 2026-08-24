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

/// [FeedPlayerPlatform] implemented on top of the generated Pigeon contracts.
///
/// Commands use the host API; events use Pigeon event channels, so payloads are
/// typed end to end instead of untyped maps filtered on the Dart side.
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
      (_playbackStateEventStream ?? playbackStateEvents()).asBroadcastStream();

  late final Stream<PositionEvent> _positions =
      (_positionEventStream ?? positionEvents()).asBroadcastStream();

  late final Stream<MetricsEvent> _metrics =
      (_metricsEventStream ?? metricsEvents()).asBroadcastStream();

  late final Stream<VideoSizeEvent> _videoSizes =
      (_videoSizeEventStream ?? videoSizeEvents()).asBroadcastStream();

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

  @override
  late final Stream<ControllerReleaseEvent> releaseEvents = _lifecycle
      .map(
        (ControllerLifecycleEvent event) => ControllerReleaseEvent(
          controllerId: event.controllerId,
          reason: releaseReasonFromMessage(event.reason),
        ),
      )
      .asBroadcastStream();

  @override
  Future<void> initialize(FeedPlayerConfig config) async {
    _ensureSupportedPlatform();
    await hostApi.initialize(config.toMessage());
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
    await hostApi.removeSources(SourceIdsRequest(sourceIds: sourceIds));
  }

  @override
  Future<int> createController({
    required String sourceId,
    required bool autoPlay,
    required bool looping,
  }) {
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
    return _positionStreams.putIfAbsent(controllerId, () {
      return _positions
          .where((PositionEvent event) => event.controllerId == controllerId)
          .map(PlaybackPosition.fromMessage);
    });
  }

  @override
  Stream<PlaybackStatusUpdate> stateStream(int controllerId) {
    return _stateStreams.putIfAbsent(controllerId, () {
      return _states
          .where(
            (PlaybackStateEvent event) => event.controllerId == controllerId,
          )
          .map(
            (PlaybackStateEvent event) => PlaybackStatusUpdate(
              state: playbackStateFromMessage(event.status),
              error: PlaybackError.fromMessage(event.error),
            ),
          );
    });
  }

  @override
  Stream<VideoMetrics> metricsStream(int controllerId) {
    return _metricsStreams.putIfAbsent(controllerId, () {
      return _metrics
          .where((MetricsEvent event) => event.controllerId == controllerId)
          .map(VideoMetrics.fromMessage);
    });
  }

  @override
  Future<void> setVolume(int controllerId, double volume) async {
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
      return _videoSizes
          .where((VideoSizeEvent event) => event.controllerId == controllerId)
          .map(VideoSize.fromMessage);
    });
  }

  @override
  Future<void> setVisibleSource(String sourceId) async {
    await hostApi.setVisibleSource(VisibleSourceRequest(sourceId: sourceId));
  }

  @override
  Future<void> evictCachedMedia(List<String> sourceIds) async {
    await hostApi.evictCachedMedia(SourceIdsRequest(sourceIds: sourceIds));
  }

  @override
  Future<void> clearMediaCache() async {
    await hostApi.clearMediaCache();
  }

  @override
  Future<CacheStatus> cacheStatus(String sourceId) async {
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
    _stateStreams.clear();
    _positionStreams.clear();
    _metricsStreams.clear();
    _videoSizeStreams.clear();
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
    _videoSizeStreams.remove(controllerId);
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

/// Former name of [MethodChannelFeedPlayer].
@Deprecated('Renamed to MethodChannelFeedPlayer. Will be removed in 0.2.0.')
typedef MethodChannelNativeFeedPlayer = MethodChannelFeedPlayer;
