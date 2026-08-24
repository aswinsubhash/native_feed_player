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
  static const int _maxCachedPlayers = 3;
  static const int _preloadCount = 1;
  static const int _controllerWindow = 1;

  final NativeFeedPlayer _player = NativeFeedPlayer();
  final PageController _pageController = PageController();
  final Map<int, VideoController> _controllers = <int, VideoController>{};
  final List<String> _urls = <String>[
    'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
    'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
    'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
    'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
  ];
  StreamSubscription<VideoPlaybackState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<VideoMetrics>? _metricsSub;
  VideoPlaybackState _status = VideoPlaybackState.idle;
  Duration _position = Duration.zero;
  VideoMetrics? _metrics;
  String? _error;
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
      await _player.initialize(
        maxCachedPlayers: _maxCachedPlayers,
        preloadCount: _preloadCount,
      );
      await _player.preload(_urls);
      await _prepareAround(0);
      await _activateFeedItem(0);
      if (!mounted) {
        return;
      }
      setState(() {
        _ready = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Failed to initialize: $error';
      });
    }
  }

  Set<int> _controllerWindowIndexes(int center) {
    return <int>{
      for (
        int candidate = center - _controllerWindow;
        candidate <= center + _controllerWindow;
        candidate += 1
      )
        if (candidate >= 0 && candidate < _urls.length) candidate,
    };
  }

  Future<VideoController> _ensureController(int index) async {
    final VideoController? cached = _controllers[index];
    if (cached != null && !cached.isReleased) {
      return cached;
    }
    if (cached != null) {
      // Native reclaimed this player; drop the dead handle and rebuild.
      _controllers.remove(index);
    }
    final VideoController controller = await _player.getController(
      url: _urls[index],
      index: index,
      autoPlay: false,
      looping: true,
    );
    _controllers[index] = controller;
    return controller;
  }

  Future<void> _disposeControllersOutside(Set<int> keepIndexes) async {
    final List<MapEntry<int, VideoController>> staleEntries = _controllers
        .entries
        .where((MapEntry<int, VideoController> entry) {
          return !keepIndexes.contains(entry.key);
        })
        .toList();

    for (final MapEntry<int, VideoController> entry in staleEntries) {
      _controllers.remove(entry.key);
      if (_activeControllerId == entry.value.controllerId) {
        _activeControllerId = null;
      }
      await entry.value.dispose();
    }
  }

  Future<void> _prepareAround(int index) async {
    final Set<int> preloadIndexes = _controllerWindowIndexes(index);
    await Future.wait(
      preloadIndexes.map((int candidate) => _ensureController(candidate)),
    );
    await _disposeControllersOutside(preloadIndexes);
    await _player.setVisibleIndex(index);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _activateFeedItem(int index) async {
    final int token = ++_activationToken;
    try {
      await _prepareAround(index);
      if (!mounted || token != _activationToken) {
        return;
      }
      final VideoController controller = await _ensureController(index);
      if (!mounted || token != _activationToken) {
        return;
      }
      await _bindCurrentStreams(controller);
      for (final MapEntry<int, VideoController> entry in _controllers.entries) {
        if (entry.key == index) {
          continue;
        }
        unawaited(entry.value.pause());
      }
      await controller.play();
    } catch (error) {
      if (!mounted || token != _activationToken) {
        return;
      }
      setState(() {
        _error = 'Playback error: $error';
      });
    }
  }

  Future<void> _bindCurrentStreams(VideoController controller) async {
    await _stateSub?.cancel();
    await _positionSub?.cancel();
    await _metricsSub?.cancel();
    _activeControllerId = controller.controllerId;

    _stateSub = controller.stateStream.listen((VideoPlaybackState state) {
      if (!mounted || _activeControllerId != controller.controllerId) {
        return;
      }
      setState(() {
        _status = state;
      });
    });
    _positionSub = controller.positionStream.listen((Duration position) {
      if (!mounted || _activeControllerId != controller.controllerId) {
        return;
      }
      setState(() {
        _position = position;
      });
    });
    _metricsSub = controller.metricsStream.listen((VideoMetrics metrics) {
      if (!mounted || _activeControllerId != controller.controllerId) {
        return;
      }
      setState(() {
        _metrics = metrics;
      });
    });
  }

  Future<void> _togglePlayback() async {
    final VideoController? controller = _controllers[_visibleIndex];
    if (controller == null) {
      return;
    }
    if (_status == VideoPlaybackState.playing ||
        _status == VideoPlaybackState.buffering) {
      await controller.pause();
      return;
    }
    await controller.play();
  }

  void _onPageChanged(int index) {
    setState(() {
      _visibleIndex = index;
      _position = Duration.zero;
      _status = VideoPlaybackState.preparing;
      _metrics = null;
    });
    unawaited(_activateFeedItem(index));
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_metricsSub?.cancel());
    _pageController.dispose();
    for (final VideoController controller in _controllers.values.toList()) {
      unawaited(controller.dispose());
    }
    _controllers.clear();
    unawaited(_player.dispose());
    super.dispose();
  }

  Widget _buildCurrentStats() {
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
                  Text('Clip ${_visibleIndex + 1} / ${_urls.length}'),
                  Text('Status: ${_status.name}'),
                  Text('Position: ${_position.inMilliseconds} ms'),
                  Text('Rebuffers: ${_metrics?.rebufferCount ?? 0}'),
                  Text(
                    'Dropped frames: ${_metrics?.droppedFramesEstimate ?? 0}',
                  ),
                  Text(
                    'First frame latency: '
                    '${_metrics?.firstFrameLatency?.inMilliseconds ?? 0} ms',
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
    final VideoController? cached = _controllers[index];
    final VideoController? controller = (cached != null && !cached.isReleased)
        ? cached
        : null;
    final String label = _urls[index].split('/').last;
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
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
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
                      itemCount: _urls.length,
                      scrollDirection: Axis.vertical,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (BuildContext context, int index) {
                        return _buildFeedPage(index);
                      },
                    ),
                    _buildCurrentStats(),
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
