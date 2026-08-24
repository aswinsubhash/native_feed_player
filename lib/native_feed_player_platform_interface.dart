import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'native_feed_player_method_channel.dart';
import 'src/controller_release.dart';
import 'src/video_metrics.dart';
import 'src/video_models.dart';
import 'src/video_playback_state.dart';

abstract class NativeFeedPlayerPlatform extends PlatformInterface {
  /// Constructs a NativeFeedPlayerPlatform.
  NativeFeedPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static NativeFeedPlayerPlatform _instance = MethodChannelNativeFeedPlayer();

  /// The default instance of [NativeFeedPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelNativeFeedPlayer].
  static NativeFeedPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NativeFeedPlayerPlatform] when
  /// they register themselves.
  static set instance(NativeFeedPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> initialize({required NativeFeedConfig config});

  Future<void> preload(List<NativeVideoSource> sources);

  Future<int> createController({
    required String url,
    required int index,
    required bool autoPlay,
    required bool looping,
  });

  Future<void> disposeController(int controllerId);

  Future<void> play(int controllerId);

  Future<void> pause(int controllerId);

  Future<void> seekTo(int controllerId, Duration position);

  Stream<Duration> positionStream(int controllerId);

  Stream<VideoPlaybackState> stateStream(int controllerId);

  Stream<VideoMetrics> metricsStream(int controllerId);

  /// Fires whenever native code releases a controller, including releases the
  /// Dart side did not request.
  Stream<ControllerReleaseEvent> get releaseEvents;

  Future<void> clearCache();

  Future<void> setVisibleIndex(int index);

  Future<void> attachView({required int controllerId, required int viewId});

  Future<void> detachView({required int controllerId});

  Future<void> dispose();
}
