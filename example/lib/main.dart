import 'dart:async';

import 'package:flutter/material.dart';
import 'package:native_feed_player/native_feed_player.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const FeedPlayerConfig _config = FeedPlayerConfig(
    maxActivePlayers: 3,
    preloadAhead: 2,
    preloadBehind: 1,
  );

  /// Controller retention radius around the visible source.
  static const int _controllerWindow = 1;

  final FeedPlayer _player = FeedPlayer();
  final PageController _pageController = PageController();
  final Map<String, FeedController> _controllers = <String, FeedController>{};

  /// Sample sources with HTTP range support.
  final List<FeedSource> _sources = <FeedSource>[
    const FeedSource(
      id: 'bee',
      uri:
          'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
    ),
    const FeedSource(
      id: 'butterfly',
      uri:
          'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4',
    ),
    const FeedSource(
      id: 'sintel',
      uri: 'https://media.w3.org/2010/05/sintel/trailer.mp4',
    ),
    const FeedSource(
      id: 'hotel-pool',
      uri:
          'https://res.cloudinary.com/demo/video/upload/c_fill,h_1920,w_1080,g_auto/hotel_pool.mp4',
    ),
    // Duplicate URI used to exercise source collapsing.
    const FeedSource(
      id: 'bee-again',
      uri:
          'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
    ),
    const FeedSource(
      id: 'butterfly-again',
      uri:
          'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4',
    ),
  ];

  StreamSubscription<PlaybackStatusUpdate>? _stateSub;
  StreamSubscription<PlaybackPosition>? _positionSub;
  StreamSubscription<VideoMetrics>? _metricsSub;

  VideoPlaybackState _status = VideoPlaybackState.idle;
  PlaybackError? _playbackError;
  PlaybackPosition _position = const PlaybackPosition(position: Duration.zero);
  VideoMetrics? _metrics;
  String? _fatalError;
  bool _ready = false;
  int _visibleIndex = 0;
  int? _activeControllerId;
  int _activationToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initializePlayer());
  }

  Future<void> _initializePlayer() async {
    try {
      await _player.initialize(config: _config);
      await _player.setSources(_sources);
      await _activate(0);
      if (!mounted) {
        return;
      }
      setState(() => _ready = true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _fatalError = 'Failed to initialize: $error');
    }
  }

  Set<int> _windowIndexes(int center) {
    return <int>{
      for (
        int candidate = center - _controllerWindow;
        candidate <= center + _controllerWindow;
        candidate += 1
      )
        if (candidate >= 0 && candidate < _sources.length) candidate,
    };
  }

  Future<FeedController> _ensureController(int index) async {
    final String sourceId = _sources[index].id;
    final FeedController? cached = _controllers[sourceId];
    if (cached != null && !cached.isReleased) {
      return cached;
    }
    // Replace a controller released by the native scheduler.
    _controllers.remove(sourceId);

    final FeedController controller = await _player.controllerFor(sourceId);
    _controllers[sourceId] = controller;
    return controller;
  }

  Future<void> _disposeControllersOutside(Set<int> keep) async {
    final Set<String> keepIds = keep
        .map((int index) => _sources[index].id)
        .toSet();
    final List<FeedController> stale = _controllers.entries
        .where((MapEntry<String, FeedController> e) => !keepIds.contains(e.key))
        .map((MapEntry<String, FeedController> e) => e.value)
        .toList();

    for (final FeedController controller in stale) {
      _controllers.remove(controller.sourceId);
      if (_activeControllerId == controller.controllerId) {
        _activeControllerId = null;
      }
    }
    await Future.wait(stale.map((FeedController c) => c.dispose()));
  }

  Future<void> _activate(int index) async {
    final int token = ++_activationToken;
    try {
      // Update scheduler ranking before creating controllers.
      await _player.setVisibleSource(_sources[index].id);

      final Set<int> window = _windowIndexes(index);
      await Future.wait(window.map(_ensureController));
      await _disposeControllersOutside(window);
      if (!mounted || token != _activationToken) {
        return;
      }

      final FeedController controller = await _ensureController(index);
      if (!mounted || token != _activationToken) {
        return;
      }

      await _bindStreams(controller);
      for (final FeedController other in _controllers.values) {
        if (other.controllerId != controller.controllerId &&
            !other.isReleased) {
          unawaited(other.pause());
        }
      }
      await controller.play();
      if (mounted) {
        setState(() {});
      }
    } on ControllerReleasedError {
      // Released during activation.
    } catch (error) {
      if (!mounted || token != _activationToken) {
        return;
      }
      setState(() => _fatalError = 'Playback error: $error');
    }
  }

  Future<void> _bindStreams(FeedController controller) async {
    await _stateSub?.cancel();
    await _positionSub?.cancel();
    await _metricsSub?.cancel();
    _activeControllerId = controller.controllerId;

    bool isCurrent() =>
        mounted && _activeControllerId == controller.controllerId;

    _stateSub = controller.stateStream.listen(
      (PlaybackStatusUpdate update) {
        if (!isCurrent()) {
          return;
        }
        setState(() {
          _status = update.state;
          _playbackError = update.error;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isCurrent()) {
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'native_feed_player_example',
            context: ErrorDescription('while listening for playback state'),
          ),
        );
      },
    );
    _positionSub = controller.positionStream.listen(
      (PlaybackPosition position) {
        if (!isCurrent()) {
          return;
        }
        setState(() => _position = position);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isCurrent()) {
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'native_feed_player_example',
            context: ErrorDescription('while listening for playback position'),
          ),
        );
      },
    );
    _metricsSub = controller.metricsStream.listen(
      (VideoMetrics metrics) {
        if (!isCurrent()) {
          return;
        }
        setState(() => _metrics = metrics);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isCurrent()) {
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'native_feed_player_example',
            context: ErrorDescription('while listening for playback metrics'),
          ),
        );
      },
    );
  }

  Future<void> _togglePlayback() async {
    final FeedController? controller = _controllers[_sources[_visibleIndex].id];
    if (controller == null || controller.isReleased) {
      return;
    }
    try {
      if (_status == VideoPlaybackState.playing ||
          _status == VideoPlaybackState.buffering) {
        await controller.pause();
      } else {
        await controller.play();
      }
    } on ControllerReleasedError {
      // Released before command dispatch.
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _visibleIndex = index;
      _position = const PlaybackPosition(position: Duration.zero);
      _status = VideoPlaybackState.preparing;
      _playbackError = null;
      _metrics = null;
    });
    unawaited(_activate(index));
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_metricsSub?.cancel());
    _pageController.dispose();
    _controllers.clear();
    final FeedPlayer player = _player;
    // State.dispose cannot await; run the native teardown to completion and
    // report failures instead of dropping them on an orphaned future.
    // FeedPlayer.dispose releases every live controller and the platform.
    unawaited(() async {
      try {
        await player.dispose();
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'native_feed_player_example',
            context: ErrorDescription('while disposing the feed player'),
          ),
        );
      }
    }());
    super.dispose();
  }

  Widget _buildStats() {
    final Duration? duration = _position.duration;
    return Positioned(
      left: 16,
      right: 16,
      top: 12,
      child: SafeArea(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.50),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: DefaultTextStyle(
              style: const TextStyle(color: Colors.white, fontSize: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Clip ${_visibleIndex + 1} / ${_sources.length}'),
                  Text('Status: ${_status.name}'),
                  Text(
                    'Position: ${_position.position.inMilliseconds} ms'
                    '${duration == null ? '' : ' / ${duration.inMilliseconds} ms'}',
                  ),
                  Text(
                    'Buffered: '
                    '${_position.bufferedPosition?.inMilliseconds ?? 0} ms',
                  ),
                  Text('Rebuffers: ${_metrics?.rebufferCount ?? 0}'),
                  Text('Dropped frames: ${_metrics?.droppedFrames ?? 0}'),
                  Text(
                    'First frame latency: '
                    '${_metrics?.firstFrameLatency?.inMilliseconds ?? 0} ms',
                  ),
                  if (_playbackError != null)
                    Text(
                      'Error: ${_playbackError!.code}'
                      '${_playbackError!.isRecoverable ? ' (retryable)' : ''}',
                      style: const TextStyle(color: Color(0xFFFF8A80)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeedPage(int index) {
    final FeedController? cached = _controllers[_sources[index].id];
    final FeedController? controller = (cached != null && !cached.isReleased)
        ? cached
        : null;
    final String label = _sources[index].id;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (controller == null)
          const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          )
        else
          NativeVideoView(controller: controller),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.black.withValues(alpha: 0.35),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.45),
              ],
              stops: const <double>[0, 0.45, 1],
            ),
          ),
        ),
        Positioned(
          left: 16,
          bottom: 32,
          right: 16,
          child: SafeArea(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: _fatalError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _fatalError!,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : !_ready
            ? const Center(child: CircularProgressIndicator())
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlayback,
                child: Stack(
                  children: <Widget>[
                    PageView.builder(
                      controller: _pageController,
                      itemCount: _sources.length,
                      scrollDirection: Axis.vertical,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (BuildContext context, int index) =>
                          _buildFeedPage(index),
                    ),
                    _buildStats(),
                  ],
                ),
              ),
        floatingActionButton: !_ready
            ? null
            : FloatingActionButton(
                onPressed: _togglePlayback,
                child: Icon(
                  _status == VideoPlaybackState.playing
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
              ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF375F),
          secondary: Color(0xFFFF375F),
        ),
      ),
    );
  }
}
