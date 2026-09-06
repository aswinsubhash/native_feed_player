// Native integration tests and benchmark output for tool/benchmark_report.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_feed_player/native_feed_player.dart';

void _emitBenchmarkSummary(Map<String, Object?> payload) {
  debugPrint('NFP_BENCHMARK_SUMMARY ${jsonEncode(payload)}');
}

int? _percentile(List<int> values, double percentile) {
  if (values.isEmpty) {
    return null;
  }
  final List<int> sorted = List<int>.from(values)..sort();
  final int index = ((sorted.length - 1) * percentile).round();
  return sorted[index];
}

class _BenchmarkCollector {
  _BenchmarkCollector(this.scenario, this.renderMode);

  final String scenario;
  final RenderMode renderMode;
  final Set<FeedController> _controllers = Set<FeedController>.identity();
  final Set<FeedController> _renderedControllers =
      Set<FeedController>.identity();

  int get firstFrameSamples => _firstFrameLatenciesMs.length;
  final Stopwatch _stopwatch = Stopwatch()..start();
  final List<StreamSubscription<VideoMetrics>> _subscriptions =
      <StreamSubscription<VideoMetrics>>[];
  final List<int> _firstFrameLatenciesMs = <int>[];
  int _metricSamples = 0;
  int _maxRebufferCount = 0;
  int _maxDroppedFrames = 0;

  void trackController(FeedController controller) {
    if (!_controllers.add(controller)) {
      return;
    }
    _subscriptions.add(
      controller.metricsStream.listen((VideoMetrics metrics) {
        _metricSamples += 1;
        if (metrics.rebufferCount > _maxRebufferCount) {
          _maxRebufferCount = metrics.rebufferCount;
        }
        if (metrics.droppedFrames > _maxDroppedFrames) {
          _maxDroppedFrames = metrics.droppedFrames;
        }
        final int? firstFrameMs = metrics.firstFrameLatency?.inMilliseconds;
        if (firstFrameMs != null &&
            firstFrameMs >= 0 &&
            _renderedControllers.add(controller)) {
          _firstFrameLatenciesMs.add(firstFrameMs);
        }
      }),
    );
  }

  Future<void> close() async {
    for (final StreamSubscription<VideoMetrics> sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _stopwatch.stop();
  }

  Map<String, Object?> get summary => <String, Object?>{
    'scenario': scenario,
    'renderMode': renderMode.name,
    'trackedControllers': _controllers.length,
    'durationMs': _stopwatch.elapsedMilliseconds,
    'metricSamples': _metricSamples,
    'firstFrameSamples': _firstFrameLatenciesMs.length,
    'firstFrameP50Ms': _percentile(_firstFrameLatenciesMs, 0.50),
    'firstFrameP95Ms': _percentile(_firstFrameLatenciesMs, 0.95),
    'maxRebufferCount': _maxRebufferCount,
    'maxDroppedFrames': _maxDroppedFrames,
    'timestampMs': DateTime.now().millisecondsSinceEpoch,
  };

  Future<void> closeAndEmit() async {
    await close();
    _emitBenchmarkSummary(summary);
  }
}

class _MetricsController implements FeedController {
  _MetricsController(this.metricsStream);

  @override
  final Stream<VideoMetrics> metricsStream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Sample sources with HTTP range support.
class _TestMediaServer {
  _TestMediaServer(this._server, this._bytes);

  final HttpServer _server;
  final List<int> _bytes;
  bool recoveryAvailable = false;

  Uri uri([String path = 'clip.mp4']) =>
      Uri.parse('http://127.0.0.1:${_server.port}/$path');

  static Future<_TestMediaServer> start() async {
    final ByteData data = await rootBundle.load('assets/test_clip.mp4');
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _TestMediaServer result = _TestMediaServer(
      server,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    server.listen((HttpRequest request) => unawaited(result._serve(request)));
    return result;
  }

  Future<void> _serve(HttpRequest request) async {
    if (request.uri.path.endsWith('/offline.mp4') ||
        (request.uri.path.endsWith('/recovery.mp4') && !recoveryAvailable)) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    int start = 0;
    int end = _bytes.length - 1;
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    final Match? match = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (match != null) {
      start = int.parse(match.group(1)!);
      if (start >= _bytes.length) {
        request.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${_bytes.length}',
          );
        await request.response.close();
        return;
      }
      final String requestedEnd = match.group(2)!;
      if (requestedEnd.isNotEmpty) {
        end = int.parse(requestedEnd).clamp(start, end);
      }
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${_bytes.length}',
        );
    }
    request.response.headers
      ..contentType = ContentType('video', 'mp4')
      ..contentLength = end - start + 1
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (request.method != 'HEAD') {
      request.response.add(_bytes.sublist(start, end + 1));
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

late String _goodUriA;
late String _goodUriB;
late String _unavailableUri;

List<FeedSource> _feed(int count) {
  return <FeedSource>[
    for (int index = 0; index < count; index += 1)
      FeedSource(id: 'clip-$index', uri: index.isEven ? _goodUriA : _goodUriB),
  ];
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final Stopwatch clock = Stopwatch()..start();
  while (clock.elapsed < duration) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<T> _waitFor<T>(WidgetTester tester, Future<T> future) async {
  bool completed = false;
  late T result;
  Object? failure;
  StackTrace? failureStack;
  unawaited(
    future.then<void>(
      (T value) {
        result = value;
        completed = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        completed = true;
      },
    ),
  );
  final Stopwatch clock = Stopwatch()..start();
  while (!completed && clock.elapsed < const Duration(seconds: 20)) {
    await _pumpFor(tester, const Duration(milliseconds: 20));
  }
  if (!completed) {
    throw TimeoutException('Timed out waiting for a native playback event.');
  }
  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack!);
  }
  return result;
}

Future<void> _mountOutput(
  WidgetTester tester,
  FeedController controller,
  RenderMode mode,
) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox.expand(
      child: NativeVideoView(controller: controller, renderMode: mode),
    ),
  ),
);

Future<void> _unmountOutput(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _pumpFor(tester, const Duration(milliseconds: 100));
}

void _registerCleanup(
  WidgetTester tester,
  FeedPlayer player, [
  _BenchmarkCollector? collector,
]) {
  addTearDown(() async {
    try {
      await _unmountOutput(tester);
    } finally {
      try {
        await collector?.close();
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });
}

Future<PlaybackStatusUpdate> _commandAndWaitForState(
  WidgetTester tester,
  FeedController controller,
  VideoPlaybackState state,
  Future<void> Function() command,
) async {
  final Completer<PlaybackStatusUpdate> event =
      Completer<PlaybackStatusUpdate>();
  final StreamSubscription<PlaybackStatusUpdate> subscription = controller
      .stateStream
      .listen((PlaybackStatusUpdate update) {
        if (update.state == state && !event.isCompleted) {
          event.complete(update);
        }
      });
  try {
    await command();
    return await _waitFor(tester, event.future);
  } finally {
    await subscription.cancel();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'collector counts first frames once per controller, including zero',
    () async {
      final StreamController<VideoMetrics> metrics =
          StreamController<VideoMetrics>.broadcast(sync: true);
      final _BenchmarkCollector collector = _BenchmarkCollector(
        'pause_resume',
        RenderMode.texture,
      );
      addTearDown(metrics.close);
      addTearDown(collector.close);
      final FeedController first = _MetricsController(metrics.stream);
      collector.trackController(first);
      collector.trackController(first);
      expect(collector.summary['trackedControllers'], 1);
      expect(collector.summary['firstFrameP50Ms'], isNull);
      expect(collector.summary['firstFrameP95Ms'], isNull);
      for (final Duration? latency in <Duration?>[
        null,
        Duration.zero,
        const Duration(milliseconds: 80),
      ]) {
        metrics.add(
          VideoMetrics(
            controllerId: 1,
            rebufferCount: 0,
            droppedFrames: 0,
            timestamp: DateTime.now(),
            firstFrameLatency: latency,
          ),
        );
      }
      expect(collector.firstFrameSamples, 1);
      expect(collector.summary['metricSamples'], 3);
      expect(collector.summary['firstFrameP50Ms'], 0);
      expect(collector.summary['firstFrameP95Ms'], 0);

      final FeedController second = _MetricsController(metrics.stream);
      collector.trackController(second);
      metrics.add(
        VideoMetrics(
          controllerId: 1,
          rebufferCount: 2,
          droppedFrames: 3,
          timestamp: DateTime.now(),
          firstFrameLatency: const Duration(milliseconds: 40),
        ),
      );
      expect(collector.firstFrameSamples, 2);
      expect(collector.summary['trackedControllers'], 2);
      expect(collector.summary['firstFrameP95Ms'], 40);
      expect(collector.summary['maxRebufferCount'], 2);
      expect(collector.summary['maxDroppedFrames'], 3);
      await collector.close();
      expect(collector.summary['firstFrameSamples'], 2);
    },
  );

  late _TestMediaServer mediaServer;

  setUpAll(() async {
    mediaServer = await _TestMediaServer.start();
    _goodUriA = mediaServer.uri('a.mp4').toString();
    _goodUriB = mediaServer.uri('b.mp4').toString();
    _unavailableUri = mediaServer.uri('offline.mp4').toString();
  });

  tearDownAll(() => mediaServer.close());

  testWidgets('initialize and create a controller', (
    WidgetTester tester,
  ) async {
    final FeedPlayer player = FeedPlayer();
    addTearDown(player.dispose);
    await player.initialize();
    await player.setSources(_feed(1));

    final FeedController controller = await player.controllerFor('clip-0');
    expect(controller.controllerId, greaterThan(0));
    expect(controller.sourceId, 'clip-0');

    await player.dispose();
  });

  testWidgets('appending a page preserves existing sources', (
    WidgetTester tester,
  ) async {
    final FeedPlayer player = FeedPlayer();
    addTearDown(player.dispose);
    await player.initialize();
    await player.setSources(_feed(3));

    final FeedController first = await player.controllerFor('clip-0');
    await player.appendSources(<FeedSource>[
      FeedSource(id: 'page2-a', uri: _goodUriA),
      FeedSource(id: 'page2-b', uri: _goodUriB),
    ]);
    await tester.pump(const Duration(milliseconds: 200));

    expect(first.isReleased, isFalse);
    expect(player.sources, hasLength(5));

    final FeedController appended = await player.controllerFor('page2-a');
    expect(appended.controllerId, greaterThan(0));

    await player.dispose();
  });

  for (final RenderMode mode in RenderMode.values) {
    testWidgets('${mode.name} output renders a first frame and detaches', (
      WidgetTester tester,
    ) async {
      final FeedPlayer player = FeedPlayer();
      _registerCleanup(tester, player);
      await player.initialize(config: FeedPlayerConfig(renderMode: mode));
      await player.setSources(_feed(1));
      final FeedController controller = await player.controllerFor('clip-0');
      await _mountOutput(tester, controller, mode);
      await controller.play();
      final Duration latency = await _waitFor(
        tester,
        controller.firstFrameRendered,
      );
      expect(latency, greaterThanOrEqualTo(Duration.zero));
      await _unmountOutput(tester);
      expect(find.byType(NativeVideoView), findsNothing);
    });

    testWidgets('${mode.name} fast fling renders during controller churn', (
      WidgetTester tester,
    ) async {
      final _BenchmarkCollector collector = _BenchmarkCollector(
        'fast_fling',
        mode,
      );
      final FeedPlayer player = FeedPlayer();
      _registerCleanup(tester, player, collector);
      await player.initialize(
        config: FeedPlayerConfig(
          renderMode: mode,
          maxActivePlayers: 3,
          preloadAhead: 2,
        ),
      );
      final List<FeedSource> sources = _feed(8);
      await player.setSources(sources);

      FeedController? previous;
      for (final FeedSource source in sources) {
        if (previous != null && !previous.isReleased) {
          await previous.pause();
        }
        await player.setVisibleSource(source.id);
        final FeedController controller = await player.controllerFor(source.id);
        collector.trackController(controller);
        previous = controller;
        expect(controller.isReleased, isFalse);
        await _mountOutput(tester, controller, mode);
        await controller.play();
        if (source == sources.first || source == sources.last) {
          final Duration latency = await _waitFor(
            tester,
            controller.firstFrameRendered,
          );
          expect(latency, greaterThanOrEqualTo(Duration.zero));
        }
        await _pumpFor(tester, const Duration(milliseconds: 120));
      }

      expect(collector.firstFrameSamples, greaterThanOrEqualTo(2));
      expect(collector.firstFrameSamples, lessThanOrEqualTo(sources.length));
      for (final FeedController controller in player.activeControllers) {
        expect(controller.isReleased, isFalse);
      }
      await collector.closeAndEmit();
    });

    testWidgets('${mode.name} playback pause and resume commands render', (
      WidgetTester tester,
    ) async {
      final _BenchmarkCollector collector = _BenchmarkCollector(
        'pause_resume',
        mode,
      );
      final FeedPlayer player = FeedPlayer();
      _registerCleanup(tester, player, collector);
      await player.initialize(config: FeedPlayerConfig(renderMode: mode));
      await player.setSources(_feed(1));
      final FeedController controller = await player.controllerFor('clip-0');
      collector.trackController(controller);
      await _mountOutput(tester, controller, mode);
      await controller.play();
      await _waitFor(tester, controller.firstFrameRendered);
      await _commandAndWaitForState(
        tester,
        controller,
        VideoPlaybackState.paused,
        controller.pause,
      );
      await _pumpFor(tester, const Duration(milliseconds: 300));
      expect(controller.isReleased, isFalse);
      await _commandAndWaitForState(
        tester,
        controller,
        VideoPlaybackState.playing,
        controller.play,
      );
      await _pumpFor(tester, const Duration(milliseconds: 600));
      expect(collector.firstFrameSamples, 1);
      await collector.closeAndEmit();
    });

    testWidgets('${mode.name} renders after local HTTP availability recovers', (
      WidgetTester tester,
    ) async {
      final _BenchmarkCollector collector = _BenchmarkCollector(
        'network_recovery',
        mode,
      );
      final FeedPlayer player = FeedPlayer();
      _registerCleanup(tester, player, collector);
      mediaServer.recoveryAvailable = false;
      await player.initialize(config: FeedPlayerConfig(renderMode: mode));
      await player.setSources(<FeedSource>[
        FeedSource(
          id: 'recovery',
          uri: mediaServer.uri('${mode.name}/recovery.mp4').toString(),
        ),
      ]);
      final FeedController bad = await player.controllerFor('recovery');
      collector.trackController(bad);
      await _commandAndWaitForState(
        tester,
        bad,
        VideoPlaybackState.error,
        bad.play,
      );
      expect(collector.firstFrameSamples, 0);
      await bad.dispose();

      mediaServer.recoveryAvailable = true;
      final FeedController recovered = await player.controllerFor('recovery');
      collector.trackController(recovered);
      await _mountOutput(tester, recovered, mode);
      await recovered.play();
      final Duration latency = await _waitFor(
        tester,
        recovered.firstFrameRendered,
      );
      expect(latency, greaterThanOrEqualTo(Duration.zero));
      await _pumpFor(tester, const Duration(milliseconds: 300));
      expect(identical(recovered, bad), isFalse);
      expect(recovered.isReleased, isFalse);
      expect(collector.firstFrameSamples, 1);
      await collector.closeAndEmit();
    });
  }

  testWidgets('missing media surfaces a typed source error', (
    WidgetTester tester,
  ) async {
    final FeedPlayer player = FeedPlayer();
    addTearDown(player.dispose);
    await player.initialize();
    await player.setSources(<FeedSource>[
      FeedSource(id: 'offline', uri: _unavailableUri),
    ]);
    final FeedController bad = await player.controllerFor('offline');
    final PlaybackStatusUpdate update = await _commandAndWaitForState(
      tester,
      bad,
      VideoPlaybackState.error,
      bad.play,
    );
    expect(update.error, isNotNull);
    // The local server's missing path is a network/HTTP failure; platform
    // mappers use either code while both classify retry as recoverable.
    expect(update.error!.code, anyOf('network_failed', 'source_not_found'));
    expect(update.error!.isRecoverable, isTrue);
  });
}
