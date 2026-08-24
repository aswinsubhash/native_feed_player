// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

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
  int _maxDroppedFramesEstimate = 0;

  void trackController(VideoController controller) {
    final StreamSubscription<VideoMetrics> sub = controller.metricsStream
        .listen((VideoMetrics metrics) {
          _metricSamples += 1;
          if (metrics.rebufferCount > _maxRebufferCount) {
            _maxRebufferCount = metrics.rebufferCount;
          }
          if (metrics.droppedFramesEstimate > _maxDroppedFramesEstimate) {
            _maxDroppedFramesEstimate = metrics.droppedFramesEstimate;
          }
          final int? firstFrameLatencyMs =
              metrics.firstFrameLatency?.inMilliseconds;
          if (firstFrameLatencyMs != null && firstFrameLatencyMs > 0) {
            _firstFrameLatenciesMs.add(firstFrameLatencyMs);
          }
        });
    _subscriptions.add(sub);
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
      'maxDroppedFramesEstimate': _maxDroppedFramesEstimate,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String goodUrlA =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';
  const String goodUrlB =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4';
  const String unreachableUrl = 'https://127.0.0.1:9/offline.mp4';

  testWidgets('initialize and create controller', (WidgetTester tester) async {
    final NativeFeedPlayer plugin = NativeFeedPlayer();
    await plugin.initialize();
    await plugin.preload(<String>[goodUrlA]);
    final VideoController controller = await plugin.getController(
      url: goodUrlA,
      index: 0,
    );
    expect(controller.controllerId, greaterThan(0));
    await plugin.dispose();
  });

  testWidgets('fast fling style visible-index churn remains stable', (
    WidgetTester tester,
  ) async {
    final _BenchmarkCollector collector = _BenchmarkCollector('fast_fling');
    final NativeFeedPlayer plugin = NativeFeedPlayer();
    await plugin.initialize(maxCachedPlayers: 5, preloadCount: 2);
    final List<String> urls = <String>[
      goodUrlA,
      goodUrlB,
      goodUrlA,
      goodUrlB,
      goodUrlA,
      goodUrlB,
      goodUrlA,
      goodUrlB,
    ];
    await plugin.preload(urls);

    final List<int> controllerIds = <int>[];
    for (int index = 0; index < urls.length; index += 1) {
      await plugin.setVisibleIndex(index);
      final VideoController controller = await plugin.getController(
        url: urls[index],
        index: index,
        autoPlay: index % 2 == 0,
      );
      collector.trackController(controller);
      controllerIds.add(controller.controllerId);
      await tester.pump(const Duration(milliseconds: 120));
    }

    await tester.pump(const Duration(milliseconds: 500));
    await collector.closeAndEmit();
    expect(controllerIds.toSet().length, urls.length);
    await plugin.dispose();
  });

  testWidgets('pause/resume lifecycle keeps controller commands usable', (
    WidgetTester tester,
  ) async {
    final _BenchmarkCollector collector = _BenchmarkCollector('pause_resume');
    final NativeFeedPlayer plugin = NativeFeedPlayer();
    await plugin.initialize();
    await plugin.preload(<String>[goodUrlA]);
    final VideoController controller = await plugin.getController(
      url: goodUrlA,
      index: 0,
    );
    collector.trackController(controller);

    await controller.play();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 300));
    await controller.pause();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    await controller.play();

    await tester.pump(const Duration(milliseconds: 600));
    await collector.closeAndEmit();
    expect(controller.controllerId, greaterThan(0));
    await plugin.dispose();
  });

  testWidgets(
    'network loss and recovery path creates new playable controller',
    (WidgetTester tester) async {
      final _BenchmarkCollector collector = _BenchmarkCollector(
        'network_recovery',
      );
      final NativeFeedPlayer plugin = NativeFeedPlayer();
      await plugin.initialize();
      await plugin.preload(<String>[unreachableUrl, goodUrlB]);

      final VideoController badController = await plugin.getController(
        url: unreachableUrl,
        index: 0,
        autoPlay: true,
      );
      collector.trackController(badController);
      await badController.play();
      await tester.pump(const Duration(milliseconds: 600));

      final VideoController recoveredController = await plugin.getController(
        url: goodUrlB,
        index: 1,
        autoPlay: true,
      );
      collector.trackController(recoveredController);
      await recoveredController.play();
      await tester.pump(const Duration(milliseconds: 800));
      await collector.closeAndEmit();

      expect(recoveredController.controllerId, greaterThan(0));
      expect(
        recoveredController.controllerId,
        isNot(badController.controllerId),
      );
      await plugin.dispose();
    },
  );
}
