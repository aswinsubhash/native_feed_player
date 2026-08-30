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

int _percentile(List<int> values, double percentile) {
  if (values.isEmpty) {
    return 0;
  }
  final List<int> sorted = List<int>.from(values)..sort();
  final int index = ((sorted.length - 1) * percentile).round();
  return sorted[index];
}

class _BenchmarkCollector {
  _BenchmarkCollector(this.scenario);

  final String scenario;
  final Stopwatch _stopwatch = Stopwatch()..start();
  final List<StreamSubscription<VideoMetrics>> _subscriptions =
      <StreamSubscription<VideoMetrics>>[];
  final List<int> _firstFrameLatenciesMs = <int>[];
  int _metricSamples = 0;
  int _maxRebufferCount = 0;
  int _maxDroppedFrames = 0;

  void trackController(FeedController controller) {
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
        if (firstFrameMs != null && firstFrameMs > 0) {
          _firstFrameLatenciesMs.add(firstFrameMs);
        }
      }),
    );
  }

  Future<void> closeAndEmit() async {
    for (final StreamSubscription<VideoMetrics> sub in _subscriptions) {
      await sub.cancel();
    }
    _stopwatch.stop();
    _emitBenchmarkSummary(<String, Object?>{
      'scenario': scenario,
      'durationMs': _stopwatch.elapsedMilliseconds,
      'metricSamples': _metricSamples,
      'firstFrameSamples': _firstFrameLatenciesMs.length,
      'firstFrameP50Ms': _percentile(_firstFrameLatenciesMs, 0.50),
      'firstFrameP95Ms': _percentile(_firstFrameLatenciesMs, 0.95),
      'maxRebufferCount': _maxRebufferCount,
      'maxDroppedFrames': _maxDroppedFrames,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }
}

// Sample sources with HTTP range support.
class _TestMediaServer {
  _TestMediaServer(this._server, this._bytes);

  final HttpServer _server;
  final List<int> _bytes;

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
    if (request.uri.path.endsWith('/offline.mp4')) {
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('texture output renders a first frame and detaches', (
    WidgetTester tester,
  ) async {
    final FeedPlayer player = FeedPlayer();
    addTearDown(player.dispose);
    await player.initialize(
      config: const FeedPlayerConfig(renderMode: RenderMode.texture),
    );
    await player.setSources(_feed(1));

    addTearDown(() async {
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
    final FeedController controller = await player.controllerFor(
      'clip-0',
      autoPlay: true,
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.expand(
          child: NativeVideoView(
            controller: controller,
            renderMode: RenderMode.texture,
          ),
        ),
      ),
    );

    final Duration latency = await controller.firstFrameRendered.timeout(
      const Duration(seconds: 20),
    );
    expect(latency, greaterThanOrEqualTo(Duration.zero));

    await player.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
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

  testWidgets('fast fling churn keeps controllers consistent', (
    WidgetTester tester,
  ) async {
    final _BenchmarkCollector collector = _BenchmarkCollector('fast_fling');
    final FeedPlayer player = FeedPlayer();
    addTearDown(player.dispose);
    await player.initialize(
      config: const FeedPlayerConfig(maxActivePlayers: 3, preloadAhead: 2),
    );

    final List<FeedSource> sources = _feed(8);
    await player.setSources(sources);

    for (final FeedSource source in sources) {
      await player.setVisibleSource(source.id);
      final FeedController controller = await player.controllerFor(
        source.id,
        autoPlay: true,
      );
      collector.trackController(controller);
      expect(controller.isReleased, isFalse);
      await tester.pump(const Duration(milliseconds: 120));
    }

    await tester.pump(const Duration(milliseconds: 500));
    await collector.closeAndEmit();

    for (final FeedController controller in player.activeControllers) {
      expect(controller.isReleased, isFalse);
    }

    await player.dispose();
  });

  testWidgets('pause/resume lifecycle keeps commands usable', (
    WidgetTester tester,
  ) async {
    final _BenchmarkCollector collector = _BenchmarkCollector('pause_resume');
    final FeedPlayer player = FeedPlayer();
    addTearDown(player.dispose);
    await player.initialize();
    await player.setSources(_feed(1));

    final FeedController controller = await player.controllerFor('clip-0');
    collector.trackController(controller);

    await controller.play();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 300));
    await controller.pause();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.isReleased, isFalse);
    await controller.play();

    await tester.pump(const Duration(milliseconds: 600));
    await collector.closeAndEmit();
    await player.dispose();
  });

  testWidgets('network failure surfaces a typed, retryable error', (
    WidgetTester tester,
  ) async {
    final _BenchmarkCollector collector = _BenchmarkCollector(
      'network_recovery',
    );
    final FeedPlayer player = FeedPlayer();
    addTearDown(player.dispose);
    await player.initialize();
    await player.setSources(<FeedSource>[
      FeedSource(id: 'offline', uri: _unavailableUri),
      FeedSource(id: 'online', uri: _goodUriB),
    ]);

    final FeedController bad = await player.controllerFor(
      'offline',
      autoPlay: true,
    );
    collector.trackController(bad);

    final Future<PlaybackStatusUpdate> failure = bad.stateStream
        .firstWhere(
          (PlaybackStatusUpdate u) => u.state == VideoPlaybackState.error,
        )
        .timeout(const Duration(seconds: 20));

    await bad.play();
    await tester.pump(const Duration(milliseconds: 600));
    final PlaybackStatusUpdate update = await failure;
    expect(update.error, isNotNull);
    expect(update.error!.code, isNotEmpty);
    expect(update.error!.isRecoverable, isTrue);

    await player.setVisibleSource('online');
    final FeedController recovered = await player.controllerFor(
      'online',
      autoPlay: true,
    );
    collector.trackController(recovered);
    await recovered.play();
    await tester.pump(const Duration(milliseconds: 800));
    await collector.closeAndEmit();

    expect(recovered.controllerId, isNot(bad.controllerId));
    await player.dispose();
  });
}
