import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'native_feed_player_method_channel.dart';
import 'src/controller_release.dart';
import 'src/feed_player_config.dart';
import 'src/feed_source.dart';
import 'src/playback_error.dart';
import 'src/video_metrics.dart';
import 'src/video_playback_state.dart';

abstract class FeedPlayerPlatform extends PlatformInterface {
  /// Constructs a FeedPlayerPlatform.
  FeedPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static FeedPlayerPlatform _instance = MethodChannelFeedPlayer();

  /// The default instance of [FeedPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelFeedPlayer].
  static FeedPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FeedPlayerPlatform] when they
  /// register themselves.
  static set instance(FeedPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> initialize(FeedPlayerConfig config);

  /// Replaces the registered feed.
  Future<void> setSources(List<FeedSource> sources);

  /// Appends a page.
  ///
  /// [rankOffset] is the absolute feed position of the first appended source,
  /// so existing sources keep their ranks and pagination cannot invalidate the
  /// preload window.
  Future<void> appendSources(
    List<FeedSource> sources, {
    required int rankOffset,
  });

  Future<void> removeSources(List<String> sourceIds);

  Future<int> createController({
    required String sourceId,
    required bool autoPlay,
    required bool looping,
  });

  Future<void> disposeController(int controllerId);

  Future<void> play(int controllerId);

  Future<void> pause(int controllerId);

  Future<void> seekTo(int controllerId, Duration position);

  Stream<PlaybackPosition> positionStream(int controllerId);

  Stream<PlaybackStatusUpdate> stateStream(int controllerId);

  Stream<VideoMetrics> metricsStream(int controllerId);

  /// Fires whenever native code releases a controller, including releases the
  /// Dart side did not request.
  Stream<ControllerReleaseEvent> get releaseEvents;

  Future<void> setVisibleSource(String sourceId);

  /// Drops cached bytes for [sourceIds], or for every source when empty.
  Future<void> evictCachedMedia(List<String> sourceIds);

  Future<void> clearMediaCache();

  Future<CacheStatus> cacheStatus(String sourceId);

  Future<int> cacheUsageBytes();

  Future<void> attachView({required int controllerId, required int viewId});

  Future<void> detachView({required int controllerId});

  Future<void> dispose();
}

/// Former name of [FeedPlayerPlatform].
@Deprecated('Renamed to FeedPlayerPlatform. Will be removed in 0.2.0.')
typedef NativeFeedPlayerPlatform = FeedPlayerPlatform;
