import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'native_reels_player_method_channel.dart';
import 'src/video_models.dart';
import 'src/video_playback_state.dart';

abstract class NativeReelsPlayerPlatform extends PlatformInterface {
  /// Constructs a NativeReelsPlayerPlatform.
  NativeReelsPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static NativeReelsPlayerPlatform _instance = MethodChannelNativeReelsPlayer();

  /// The default instance of [NativeReelsPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelNativeReelsPlayer].
  static NativeReelsPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NativeReelsPlayerPlatform] when
  /// they register themselves.
  static set instance(NativeReelsPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> initialize({required NativeReelsConfig config});

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

  Future<void> clearCache();

  Future<void> setVisibleIndex(int index);

  Future<void> attachView({required int controllerId, required int viewId});

  Future<void> detachView({required int controllerId});

  Future<void> dispose();
}
