import 'dart:async';
import 'dart:collection';

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
  final Queue<Future<void> Function()> _mutationQueue =
      Queue<Future<void> Function()>();
  Future<void>? _disposeOperation;
  bool _mutationRunning = false;
  FeedPlayerConfig _config = const FeedPlayerConfig();
  bool _initialized = false;
  bool _disposeRequested = false;

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
  }) {
    _ensureNotDisposed();
    config.toMessage();
    return _serialize(() async {
      await _platform.initialize(config);
      _releaseAllControllers();
      _sources.clear();
      _config = config;
      _initialized = true;
    });
  }

  /// Replaces the whole feed.
  Future<void> setSources(List<FeedSource> sources) {
    _ensureNotDisposed();
    final List<FeedSource> nextSources = List<FeedSource>.unmodifiable(sources);
    _validateSources(nextSources);
    _assertUniqueIds(nextSources);
    return _serialize(() async {
      _ensureInitialized();
      final Map<String, FeedSource> replacements = <String, FeedSource>{
        for (final FeedSource source in nextSources) source.id: source,
      };
      final List<FeedController> removedControllers = <FeedController>[
        for (final FeedController controller
            in _controllersBySourceId.values.toList())
          if (_sourceFor(controller.sourceId) !=
              replacements[controller.sourceId])
            controller,
      ];

      await _platform.setSources(nextSources);

      _sources
        ..clear()
        ..addAll(nextSources);
      for (final FeedController controller in removedControllers) {
        controller.markReleased(ControllerReleaseReason.disposed);
      }
    });
  }

  /// Appends sources without renumbering existing entries.
  Future<void> appendSources(List<FeedSource> sources) {
    _ensureNotDisposed();
    final List<FeedSource> appended = List<FeedSource>.unmodifiable(sources);
    _validateSources(appended);
    _assertUniqueIds(appended);
    return _serialize(() async {
      _ensureInitialized();
      if (appended.isEmpty) {
        return;
      }
      _assertUniqueIds(<FeedSource>[..._sources, ...appended]);
      final int rankOffset = _sources.length;
      await _platform.appendSources(appended, rankOffset: rankOffset);
      _sources.addAll(appended);
    });
  }

  Future<void> removeSources(List<String> sourceIds) {
    _ensureNotDisposed();
    final List<String> requestedIds = List<String>.unmodifiable(sourceIds);
    for (final String sourceId in requestedIds) {
      _validateId(sourceId, 'sourceIds');
    }
    return _serialize(() async {
      _ensureInitialized();
      if (requestedIds.isEmpty) {
        return;
      }
      await _platform.removeSources(requestedIds);
      final Set<String> removed = requestedIds.toSet();
      _sources.removeWhere((FeedSource source) => removed.contains(source.id));
      for (final String sourceId in removed) {
        _controllersBySourceId[sourceId]?.markReleased(
          ControllerReleaseReason.disposed,
        );
      }
    });
  }

  /// Returns a live controller for [sourceId], creating one if needed.
  Future<FeedController> controllerFor(
    String sourceId, {
    bool autoPlay = false,
    bool looping = true,
  }) {
    _ensureNotDisposed();
    _validateId(sourceId, 'sourceId');
    return _serialize(() async {
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
    });
  }

  /// Sets the visible source used for preload and eviction ranking.
  Future<void> setVisibleSource(String sourceId) {
    _ensureNotDisposed();
    _validateId(sourceId, 'sourceId');
    return _serialize(() async {
      _ensureInitialized();
      if (!_sources.any((FeedSource source) => source.id == sourceId)) {
        throw ArgumentError.value(
          sourceId,
          'sourceId',
          'Register the source with setSources/appendSources first.',
        );
      }
      await _platform.setVisibleSource(sourceId);
    });
  }

  /// Changes audio behaviour for every controller, current and future.
  Future<void> setAudioPolicy(AudioPolicy policy) {
    _ensureNotDisposed();
    policy.toMessage();
    return _serialize(() async {
      _ensureInitialized();
      await _platform.setAudioPolicy(policy);
      _config = _config.copyWith(audio: policy);
    });
  }

  /// Mutes or unmutes current and future controllers.
  Future<void> setMuted(bool muted) {
    _ensureNotDisposed();
    return _serialize(() async {
      _ensureInitialized();
      final AudioPolicy policy = _config.audio.copyWith(muted: muted);
      policy.toMessage();
      await _platform.setAudioPolicy(policy);
      _config = _config.copyWith(audio: policy);
    });
  }

  /// Drops cached media bytes for [sourceIds], or all sources when omitted.
  Future<void> evictCachedMedia([List<String> sourceIds = const <String>[]]) {
    _ensureNotDisposed();
    final List<String> requestedIds = List<String>.unmodifiable(sourceIds);
    for (final String sourceId in requestedIds) {
      _validateId(sourceId, 'sourceIds');
    }
    return _serialize(() => _platform.evictCachedMedia(requestedIds));
  }

  /// Clears the persistent media cache.
  Future<void> clearMediaCache() {
    _ensureNotDisposed();
    return _serialize(_platform.clearMediaCache);
  }

  Future<CacheStatus> cacheStatus(String sourceId) {
    _ensureNotDisposed();
    _validateId(sourceId, 'sourceId');
    return _serialize(() => _platform.cacheStatus(sourceId));
  }

  Future<int> cacheUsageBytes() {
    _ensureNotDisposed();
    return _serialize(_platform.cacheUsageBytes);
  }

  Future<void> dispose() {
    final Future<void>? operation = _disposeOperation;
    if (operation != null) {
      return operation;
    }
    _disposeRequested = true;
    return _disposeOperation = _serialize(() async {
      try {
        try {
          await _releaseSubscription?.cancel();
        } finally {
          _releaseSubscription = null;
          await _platform.dispose();
        }
      } finally {
        _releaseAllControllers();
        _sources.clear();
        _initialized = false;
      }
    });
  }

  void _onNativeRelease(ControllerReleaseEvent event) {
    final String? sourceId = _sourceIdsByControllerId[event.controllerId];
    if (sourceId == null) {
      return;
    }
    final FeedController? controller = _controllersBySourceId[sourceId];
    if (controller == null || controller.controllerId != event.controllerId) {
      _sourceIdsByControllerId.remove(event.controllerId);
      return;
    }
    controller.markReleased(event.reason);
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

  void _releaseAllControllers() {
    for (final FeedController controller
        in _controllersBySourceId.values.toList()) {
      controller.markReleased(ControllerReleaseReason.disposed);
    }
    _controllersBySourceId.clear();
    _sourceIdsByControllerId.clear();
  }

  FeedSource? _sourceFor(String sourceId) {
    for (final FeedSource source in _sources) {
      if (source.id == sourceId) {
        return source;
      }
    }
    return null;
  }

  Future<T> _serialize<T>(FutureOr<T> Function() operation) {
    final Completer<T> completer = Completer<T>();
    _mutationQueue.add(() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    if (!_mutationRunning) {
      _mutationRunning = true;
      unawaited(_drainMutations());
    }
    return completer.future;
  }

  Future<void> _drainMutations() async {
    while (_mutationQueue.isNotEmpty) {
      await _mutationQueue.removeFirst()();
    }
    _mutationRunning = false;
  }

  void _validateSources(List<FeedSource> sources) {
    for (int index = 0; index < sources.length; index += 1) {
      sources[index].toMessage(index);
    }
  }

  void _validateId(String id, String name) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, name, 'Must not be empty.');
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

  void _ensureNotDisposed() {
    if (_disposeRequested) {
      throw StateError('FeedPlayer has been disposed.');
    }
  }
}
