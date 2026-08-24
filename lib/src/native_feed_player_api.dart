import 'dart:async';

import '../native_feed_player_platform_interface.dart';
import 'controller_release.dart';
import 'video_controller.dart';
import 'video_models.dart';

/// Main Dart API for feed-oriented native playback with pre-buffering.
///
/// Native code owns controller lifetime and may reclaim players without being
/// asked (window eviction, memory pressure). This class subscribes to native
/// release events so its controller cache can never hand out a handle whose
/// native player is already gone.
class NativeFeedPlayer {
  NativeFeedPlayer({NativeFeedPlayerPlatform? platform})
    : _platform = platform ?? NativeFeedPlayerPlatform.instance {
    _releaseSubscription = _platform.releaseEvents.listen(_onNativeRelease);
  }

  final NativeFeedPlayerPlatform _platform;
  final Map<String, VideoController> _controllersByKey =
      <String, VideoController>{};
  final Map<int, String> _keysByControllerId = <int, String>{};

  StreamSubscription<ControllerReleaseEvent>? _releaseSubscription;
  NativeFeedConfig _config = const NativeFeedConfig();
  bool _initialized = false;

  Future<void> initialize({
    int maxCachedPlayers = 5,
    int preloadCount = 2,
  }) async {
    _config = NativeFeedConfig(
      maxCachedPlayers: maxCachedPlayers,
      preloadCount: preloadCount,
    );
    await _platform.initialize(config: _config);
    _initialized = true;
  }

  Future<void> preload(List<String> urls) async {
    _ensureInitialized();
    final List<NativeVideoSource> sources = <NativeVideoSource>[
      for (int index = 0; index < urls.length; index += 1)
        NativeVideoSource(url: urls[index], index: index),
    ];
    await _platform.preload(sources);
  }

  Future<VideoController> getController({
    required String url,
    required int index,
    bool autoPlay = false,
    bool looping = true,
  }) async {
    _ensureInitialized();
    final String key = _controllerKey(url, index);
    final VideoController? cached = _controllersByKey[key];
    if (cached != null && !cached.isReleased) {
      return cached;
    }
    if (cached != null) {
      _forget(cached);
    }

    final int controllerId = await _platform.createController(
      url: url,
      index: index,
      autoPlay: autoPlay,
      looping: looping,
    );
    final VideoController controller = VideoController(
      controllerId: controllerId,
      url: url,
      index: index,
      platform: _platform,
      onReleasedCallback: _forget,
    );
    _controllersByKey[key] = controller;
    _keysByControllerId[controllerId] = key;
    return controller;
  }

  /// Controllers currently known to be alive.
  Iterable<VideoController> get activeControllers =>
      List<VideoController>.unmodifiable(_controllersByKey.values);

  Future<void> clearCache() async {
    await _platform.clearCache();
  }

  Future<void> setVisibleIndex(int index) => _platform.setVisibleIndex(index);

  Future<void> dispose() async {
    await _releaseSubscription?.cancel();
    _releaseSubscription = null;
    for (final VideoController controller
        in _controllersByKey.values.toList()) {
      controller.markReleased(ControllerReleaseReason.disposed);
    }
    _controllersByKey.clear();
    _keysByControllerId.clear();
    await _platform.dispose();
    _initialized = false;
  }

  void _onNativeRelease(ControllerReleaseEvent event) {
    final String? key = _keysByControllerId[event.controllerId];
    if (key == null) {
      return;
    }
    _controllersByKey[key]?.markReleased(event.reason);
  }

  void _forget(VideoController controller) {
    final String? key = _keysByControllerId.remove(controller.controllerId);
    if (key == null) {
      return;
    }
    if (identical(_controllersByKey[key], controller)) {
      _controllersByKey.remove(key);
    }
  }

  String _controllerKey(String url, int index) => '$index::$url';

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'NativeFeedPlayer must be initialized before calling this method.',
      );
    }
  }
}
