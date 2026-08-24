import '../native_feed_player_platform_interface.dart';
import 'video_controller.dart';
import 'video_models.dart';

/// Main Dart API for feed-oriented native playback with pre-buffering.
class NativeFeedPlayer {
  NativeFeedPlayer({NativeFeedPlayerPlatform? platform})
    : _platform = platform ?? NativeFeedPlayerPlatform.instance;

  final NativeFeedPlayerPlatform _platform;
  final Map<String, VideoController> _controllersByKey =
      <String, VideoController>{};
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
    if (cached != null) {
      return cached;
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
    );
    _controllersByKey[key] = controller;
    return controller;
  }

  Future<void> clearCache() async {
    await _platform.clearCache();
    _controllersByKey.clear();
  }

  Future<void> setVisibleIndex(int index) => _platform.setVisibleIndex(index);

  Future<void> dispose() async {
    final Iterable<VideoController> controllers = _controllersByKey.values;
    for (final VideoController controller in controllers) {
      await controller.dispose();
    }
    _controllersByKey.clear();
    await _platform.dispose();
    _initialized = false;
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
