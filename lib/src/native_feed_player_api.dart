import 'dart:async';

import '../native_feed_player_platform_interface.dart';
import 'controller_release.dart';
import 'feed_player_config.dart';
import 'feed_source.dart';
import 'playback_error.dart';
import 'video_controller.dart';

/// Coordinates feed sources and native playback controllers.
///
/// Source identifiers remain stable across pagination. Controllers may be
/// released by the native scheduler.
class FeedPlayer {
  FeedPlayer({FeedPlayerPlatform? platform})
    : _platform = platform ?? FeedPlayerPlatform.instance {
    _releaseSubscription = _platform.releaseEvents.listen(_onNativeRelease);
  }

  final FeedPlayerPlatform _platform;

  /// Registered sources in feed order. Order defines preload ranking.
  final List<FeedSource> _sources = <FeedSource>[];
  final Map<String, FeedController> _controllersBySourceId =
      <String, FeedController>{};
  final Map<int, String> _sourceIdsByControllerId = <int, String>{};

  StreamSubscription<ControllerReleaseEvent>? _releaseSubscription;
  FeedPlayerConfig _config = const FeedPlayerConfig();
  bool _initialized = false;

  FeedPlayerConfig get config => _config;

  /// Registered sources, in feed order.
  List<FeedSource> get sources => List<FeedSource>.unmodifiable(_sources);

  /// Controllers currently known to be alive.
  Iterable<FeedController> get activeControllers =>
      List<FeedController>.unmodifiable(_controllersBySourceId.values);

  /// Initializes this engine's playback session.
  ///
  /// Reinitialization releases the previous session.
  Future<void> initialize({
    FeedPlayerConfig config = const FeedPlayerConfig(),
  }) async {
    for (final FeedController controller
        in _controllersBySourceId.values.toList()) {
      controller.markReleased(ControllerReleaseReason.disposed);
    }
    _controllersBySourceId.clear();
    _sourceIdsByControllerId.clear();
    _sources.clear();
    _initialized = false;
    _config = config;
    await _platform.initialize(config);
    _initialized = true;
  }

  /// Replaces the whole feed.
  Future<void> setSources(List<FeedSource> sources) async {
    _ensureInitialized();
    _assertUniqueIds(sources);
    _sources
      ..clear()
      ..addAll(sources);
    await _platform.setSources(sources);
  }

  /// Appends sources without renumbering existing entries.
  Future<void> appendSources(List<FeedSource> sources) async {
    _ensureInitialized();
    if (sources.isEmpty) {
      return;
    }
    _assertUniqueIds(<FeedSource>[..._sources, ...sources]);
    final int rankOffset = _sources.length;
    _sources.addAll(sources);
    await _platform.appendSources(sources, rankOffset: rankOffset);
  }

  Future<void> removeSources(List<String> sourceIds) async {
    _ensureInitialized();
    if (sourceIds.isEmpty) {
      return;
    }
    final Set<String> removed = sourceIds.toSet();
    _sources.removeWhere((FeedSource source) => removed.contains(source.id));
    for (final String sourceId in removed) {
      _controllersBySourceId[sourceId]?.markReleased(
        ControllerReleaseReason.disposed,
      );
    }
    await _platform.removeSources(sourceIds);
  }

  /// Returns a live controller for [sourceId], creating one if needed.
  Future<FeedController> controllerFor(
    String sourceId, {
    bool autoPlay = false,
    bool looping = true,
  }) async {
    _ensureInitialized();
    if (!_sources.any((FeedSource source) => source.id == sourceId)) {
      throw ArgumentError.value(
        sourceId,
        'sourceId',
        'Register the source with setSources/appendSources first.',
      );
    }

    final FeedController? cached = _controllersBySourceId[sourceId];
    if (cached != null && !cached.isReleased) {
      return cached;
    }
    if (cached != null) {
      _forget(cached);
    }

    final int controllerId = await _platform.createController(
      sourceId: sourceId,
      autoPlay: autoPlay,
      looping: looping,
    );
    final FeedController controller = FeedController(
      controllerId: controllerId,
      sourceId: sourceId,
      platform: _platform,
      onReleasedCallback: _forget,
    );
    _controllersBySourceId[sourceId] = controller;
    _sourceIdsByControllerId[controllerId] = sourceId;
    return controller;
  }

  /// Sets the visible source used for preload and eviction ranking.
  Future<void> setVisibleSource(String sourceId) {
    _ensureInitialized();
    return _platform.setVisibleSource(sourceId);
  }

  /// Changes audio behaviour for every controller, current and future.
  Future<void> setAudioPolicy(AudioPolicy policy) async {
    _ensureInitialized();
    _config = _config.copyWith(audio: policy);
    await _platform.setAudioPolicy(policy);
  }

  /// Mutes or unmutes current and future controllers.
  Future<void> setMuted(bool muted) =>
      setAudioPolicy(_config.audio.copyWith(muted: muted));

  /// Drops cached media bytes for [sourceIds], or all sources when omitted.
  Future<void> evictCachedMedia([List<String> sourceIds = const <String>[]]) =>
      _platform.evictCachedMedia(sourceIds);

  /// Clears the persistent media cache.
  Future<void> clearMediaCache() => _platform.clearMediaCache();

  Future<CacheStatus> cacheStatus(String sourceId) =>
      _platform.cacheStatus(sourceId);

  Future<int> cacheUsageBytes() => _platform.cacheUsageBytes();

  Future<void> dispose() async {
    await _releaseSubscription?.cancel();
    _releaseSubscription = null;
    for (final FeedController controller
        in _controllersBySourceId.values.toList()) {
      controller.markReleased(ControllerReleaseReason.disposed);
    }
    _controllersBySourceId.clear();
    _sourceIdsByControllerId.clear();
    _sources.clear();
    await _platform.dispose();
    _initialized = false;
  }

  void _onNativeRelease(ControllerReleaseEvent event) {
    final String? sourceId = _sourceIdsByControllerId[event.controllerId];
    if (sourceId == null) {
      return;
    }
    _controllersBySourceId[sourceId]?.markReleased(event.reason);
  }

  void _forget(FeedController controller) {
    final String? sourceId = _sourceIdsByControllerId.remove(
      controller.controllerId,
    );
    if (sourceId == null) {
      return;
    }
    if (identical(_controllersBySourceId[sourceId], controller)) {
      _controllersBySourceId.remove(sourceId);
    }
  }

  void _assertUniqueIds(List<FeedSource> sources) {
    final Set<String> seen = <String>{};
    for (final FeedSource source in sources) {
      if (!seen.add(source.id)) {
        throw ArgumentError.value(
          source.id,
          'sources',
          'Duplicate FeedSource id. Ids must be unique across the feed.',
        );
      }
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'FeedPlayer must be initialized before calling this method.',
      );
    }
  }
}
