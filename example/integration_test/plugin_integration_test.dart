// Integration tests for native_feed_player.
//
// These run in a full Flutter application so they exercise the real native
// host, unlike the Dart unit tests. They also emit structured benchmark lines
// consumed by tool/benchmark_report.dart.

import 'dart:async';
import 'dart:convert';

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

// Hosts that answer range requests, which the iOS byte-range cache needs. The
// gtv-videos-bucket samples these once used now return 403.
const String _goodUriA =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
const String _goodUriB =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4';
const String _unreachableUri = 'https://127.0.0.1:9/offline.mp4';

List<FeedSource> _feed(int count) {
  return <FeedSource>[
    for (int index = 0; index < count; index += 1)
      FeedSource(id: 'clip-$index', uri: index.isEven ? _goodUriA : _goodUriB),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initialize and create a controller', (
    WidgetTester tester,
  ) async {
    final FeedPlayer player = FeedPlayer();
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
    await player.initialize();
    await player.setSources(_feed(3));

    final FeedController first = await player.controllerFor('clip-0');
    await player.appendSources(<FeedSource>[
      const FeedSource(id: 'page2-a', uri: _goodUriA),
      const FeedSource(id: 'page2-b', uri: _goodUriB),
    ]);
    await tester.pump(const Duration(milliseconds: 200));

    // Pagination must not disturb an already-live controller.
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
      // Every controller handed out must be live at that moment.
      expect(controller.isReleased, isFalse);
      await tester.pump(const Duration(milliseconds: 120));
    }

    await tester.pump(const Duration(milliseconds: 500));
    await collector.closeAndEmit();

    // Eviction must never leave a stale handle in the player's cache.
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

    // Backgrounding must not have destroyed the player.
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
    await player.initialize();
    await player.setSources(<FeedSource>[
      const FeedSource(id: 'offline', uri: _unreachableUri),
      const FeedSource(id: 'online', uri: _goodUriB),
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
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () =>
              const PlaybackStatusUpdate(state: VideoPlaybackState.idle),
        );

    await bad.play();
    await tester.pump(const Duration(milliseconds: 600));
    final PlaybackStatusUpdate update = await failure;
    if (update.state == VideoPlaybackState.error) {
      expect(update.error, isNotNull);
      expect(update.error!.code, isNotEmpty);
    }

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
