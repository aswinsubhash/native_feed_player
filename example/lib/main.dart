import 'dart:async';

import 'package:flutter/material.dart';
import 'package:native_reels_player/native_reels_player.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final NativeReelsPlayer _player = NativeReelsPlayer();
  VideoController? _controller;
  StreamSubscription<VideoPlaybackState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  String _status = 'idle';
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    await _player.initialize(maxCachedPlayers: 5, preloadCount: 2);
    await _player.preload(<String>[
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
    ]);

    final VideoController controller = await _player.getController(
      url:
          'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
      index: 0,
    );

    if (!mounted) return;
    setState(() {
      _controller = controller;
      _status = 'ready';
    });

    _stateSub = controller.stateStream.listen((VideoPlaybackState state) {
      if (!mounted) return;
      setState(() {
        _status = state.name;
      });
    });
    _positionSub = controller.positionStream.listen((Duration position) {
      if (!mounted) return;
      setState(() {
        _position = position;
      });
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_controller == null) return;
    await _controller!.play();
  }

  Future<void> _pause() async {
    if (_controller == null) return;
    await _controller!.pause();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Native Reels Player Example')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Status: $_status'),
              Text('Position: ${_position.inMilliseconds} ms'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _controller == null ? null : _play,
                child: const Text('Play'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _controller == null ? null : _pause,
                child: const Text('Pause'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Milestone 2 note: playback, state, and position events are native. '
                'Video rendering widget is still pending.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
