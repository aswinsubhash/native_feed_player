import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_feed_player/native_feed_player.dart';
import 'package:native_feed_player/native_feed_player_method_channel.dart';
import 'package:native_feed_player/native_feed_player_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakeFeedPlayerPlatform
    with MockPlatformInterfaceMixin
    implements FeedPlayerPlatform {
  final StreamController<ControllerReleaseEvent> releaseController =
      StreamController<ControllerReleaseEvent>.broadcast();

  final List<int> disposedControllerIds = <int>[];
  final List<String> visibleSourceIds = <String>[];
  final List<List<FeedSource>> setSourceCalls = <List<FeedSource>>[];
  final List<(List<FeedSource>, int)> appendCalls = <(List<FeedSource>, int)>[];
  final List<(int, double)> volumeCalls = <(int, double)>[];
  final List<(int, bool)> mutedCalls = <(int, bool)>[];
  final List<(int, double)> speedCalls = <(int, double)>[];
  final List<(int, bool)> loopingCalls = <(int, bool)>[];
  final List<AudioPolicy> audioPolicies = <AudioPolicy>[];

  FeedPlayerConfig? initializedWith;
  int nextControllerId = 1;

  @override
  Stream<ControllerReleaseEvent> get releaseEvents => releaseController.stream;

  @override
  Future<void> initialize(FeedPlayerConfig config) async {
    initializedWith = config;
  }

  @override
  Future<void> setSources(List<FeedSource> sources) async {
    setSourceCalls.add(sources);
  }

  @override
  Future<void> appendSources(
    List<FeedSource> sources, {
    required int rankOffset,
  }) async {
    appendCalls.add((sources, rankOffset));
  }

  @override
  Future<void> removeSources(List<String> sourceIds) async {}

  @override
  Future<int> createController({
    required String sourceId,
    required bool autoPlay,
    required bool looping,
  }) async {
    return nextControllerId++;
  }

  @override
  Future<void> disposeController(int controllerId) async {
    disposedControllerIds.add(controllerId);
  }

  @override
  Future<void> play(int controllerId) async {}

  @override
  Future<void> pause(int controllerId) async {}

  @override
  Future<void> seekTo(int controllerId, Duration position) async {}

  @override
  Stream<PlaybackPosition> positionStream(int controllerId) =>
      const Stream<PlaybackPosition>.empty();

  @override
  Stream<PlaybackStatusUpdate> stateStream(int controllerId) =>
      const Stream<PlaybackStatusUpdate>.empty();

  @override
  Stream<VideoMetrics> metricsStream(int controllerId) =>
      const Stream<VideoMetrics>.empty();

  @override
  Future<void> setVolume(int controllerId, double volume) async {
    volumeCalls.add((controllerId, volume));
  }

  @override
  Future<void> setMuted(int controllerId, bool muted) async {
    mutedCalls.add((controllerId, muted));
  }

  @override
  Future<void> setPlaybackSpeed(int controllerId, double speed) async {
    speedCalls.add((controllerId, speed));
  }

  @override
  Future<void> setLooping(int controllerId, bool looping) async {
    loopingCalls.add((controllerId, looping));
  }

  @override
  Future<void> setAudioPolicy(AudioPolicy policy) async {
    audioPolicies.add(policy);
  }

  @override
  Stream<VideoSize> videoSizeStream(int controllerId) =>
      const Stream<VideoSize>.empty();

  @override
  Future<void> setVisibleSource(String sourceId) async {
    visibleSourceIds.add(sourceId);
  }

  @override
  Future<void> evictCachedMedia(List<String> sourceIds) async {}

  @override
  Future<void> clearMediaCache() async {}

  @override
  Future<CacheStatus> cacheStatus(String sourceId) async => CacheStatus(
    sourceId: sourceId,
    cachedBytes: 0,
    totalBytes: 0,
    isComplete: false,
  );

  @override
  Future<int> cacheUsageBytes() async => 0;

  @override
  Future<void> attachView({
    required int controllerId,
    required int viewId,
  }) async {}

  @override
  Future<void> detachView({required int controllerId}) async {}

  @override
  Future<int> attachTexture(int controllerId) async => controllerId + 1000;

  @override
  Future<void> detachTexture(int controllerId) async {}

  @override
  Future<void> dispose() async {}
}

FeedSource _source(String id) =>
    FeedSource(id: id, uri: 'https://example.test/$id.mp4');

void main() {
  test('$MethodChannelFeedPlayer is the default instance', () {
    expect(
      FeedPlayerPlatform.instance,
      isInstanceOf<MethodChannelFeedPlayer>(),
    );
  });

  group('FeedPlayer', () {
    late FakeFeedPlayerPlatform platform;
    late FeedPlayer player;

    setUp(() async {
      platform = FakeFeedPlayerPlatform();
      player = FeedPlayer(platform: platform);
      await player.initialize();
    });

    tearDown(() async {
      await platform.releaseController.close();
    });

    test('defaults are feed-appropriate', () {
      final FeedPlayerConfig config = platform.initializedWith!;
      expect(config.maxActivePlayers, 3);
      expect(config.preloadAhead, greaterThan(config.preloadBehind));
      expect(config.audio.muted, isTrue);
      expect(config.cache.enabled, isTrue);
      expect(config.cache.maxBytes, 256 * 1024 * 1024);
    });

    test('setSources registers the feed in order', () async {
      await player.setSources(<FeedSource>[_source('a'), _source('b')]);

      expect(
        platform.setSourceCalls.single.map((FeedSource s) => s.id),
        <String>['a', 'b'],
      );
      expect(player.sources, hasLength(2));
    });

    test('appendSources offsets ranks instead of renumbering', () async {
      await player.setSources(<FeedSource>[_source('a'), _source('b')]);
      await player.appendSources(<FeedSource>[_source('c'), _source('d')]);

      final (List<FeedSource> appended, int offset) =
          platform.appendCalls.single;
      expect(offset, 2, reason: 'page 2 starts after the two existing sources');
      expect(appended.map((FeedSource s) => s.id), <String>['c', 'd']);
      expect(player.sources.map((FeedSource s) => s.id), <String>[
        'a',
        'b',
        'c',
        'd',
      ]);
    });

    test('appending an empty page is a no-op', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      await player.appendSources(<FeedSource>[]);

      expect(platform.appendCalls, isEmpty);
    });

    test('duplicate source ids are rejected', () async {
      expect(
        () => player.setSources(<FeedSource>[_source('a'), _source('a')]),
        throwsArgumentError,
      );
    });

    test('appending a colliding id is rejected', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      expect(
        () => player.appendSources(<FeedSource>[_source('a')]),
        throwsArgumentError,
      );
    });

    test('controllerFor requires a registered source', () async {
      expect(() => player.controllerFor('missing'), throwsArgumentError);
    });

    test('controllerFor reuses a live controller', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController first = await player.controllerFor('a');
      final FeedController second = await player.controllerFor('a');

      expect(identical(first, second), isTrue);
    });

    test('controller commands reach the platform', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController controller = await player.controllerFor('a');

      await controller.setVolume(0.5);
      await controller.setMuted(false);
      await controller.setPlaybackSpeed(1.5);
      await controller.setLooping(false);

      final int id = controller.controllerId;
      expect(platform.volumeCalls, <(int, double)>[(id, 0.5)]);
      expect(platform.mutedCalls, <(int, bool)>[(id, false)]);
      expect(platform.speedCalls, <(int, double)>[(id, 1.5)]);
      expect(platform.loopingCalls, <(int, bool)>[(id, false)]);
    });

    test('volume is clamped before it reaches the platform', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController controller = await player.controllerFor('a');

      await controller.setVolume(3.2);
      await controller.setVolume(-1);

      expect(
        platform.volumeCalls.map(((int, double) call) => call.$2),
        <double>[1.0, 0.0],
      );
    });

    test('setMuted updates the retained audio policy', () async {
      expect(player.config.audio.muted, isTrue);

      await player.setMuted(false);

      expect(platform.audioPolicies.single.muted, isFalse);
      expect(player.config.audio.muted, isFalse);
      // Other config must survive the targeted change.
      expect(player.config.maxActivePlayers, 3);
      expect(player.config.cache.maxBytes, 256 * 1024 * 1024);
    });

    test('uninitialized use is rejected', () {
      final FeedPlayer fresh = FeedPlayer(platform: FakeFeedPlayerPlatform());
      expect(() => fresh.setSources(<FeedSource>[]), throwsStateError);
    });
  });

  group('native release reconciliation', () {
    late FakeFeedPlayerPlatform platform;
    late FeedPlayer player;

    setUp(() async {
      platform = FakeFeedPlayerPlatform();
      player = FeedPlayer(platform: platform);
      await player.initialize();
      await player.setSources(<FeedSource>[_source('a'), _source('b')]);
    });

    tearDown(() async {
      await platform.releaseController.close();
    });

    test('eviction purges the controller cache', () async {
      final FeedController controller = await player.controllerFor('a');
      expect(player.activeControllers, hasLength(1));

      platform.releaseController.add(
        ControllerReleaseEvent(
          controllerId: controller.controllerId,
          reason: ControllerReleaseReason.evicted,
        ),
      );
      await controller.onReleased;

      expect(controller.isReleased, isTrue);
      expect(controller.releaseReason, ControllerReleaseReason.evicted);
      expect(player.activeControllers, isEmpty);
    });

    test('controllerFor rebuilds after eviction', () async {
      final FeedController first = await player.controllerFor('a');
      platform.releaseController.add(
        ControllerReleaseEvent(
          controllerId: first.controllerId,
          reason: ControllerReleaseReason.evicted,
        ),
      );
      await first.onReleased;

      final FeedController second = await player.controllerFor('a');

      expect(second.controllerId, isNot(first.controllerId));
      expect(second.isReleased, isFalse);
    });

    test('commands on a released controller throw', () async {
      final FeedController controller = await player.controllerFor('a');
      platform.releaseController.add(
        ControllerReleaseEvent(
          controllerId: controller.controllerId,
          reason: ControllerReleaseReason.evicted,
        ),
      );
      await controller.onReleased;

      expect(controller.play, throwsA(isA<ControllerReleasedError>()));
      expect(controller.pause, throwsA(isA<ControllerReleasedError>()));
      expect(
        () => controller.seekTo(Duration.zero),
        throwsA(isA<ControllerReleasedError>()),
      );
    });

    test('dispose is idempotent and removes the cache entry', () async {
      final FeedController controller = await player.controllerFor('a');

      await controller.dispose();
      await controller.dispose();

      expect(platform.disposedControllerIds, <int>[controller.controllerId]);
      expect(player.activeControllers, isEmpty);
      expect(controller.releaseReason, ControllerReleaseReason.disposed);
    });

    test('removeSources releases the matching controller', () async {
      final FeedController controller = await player.controllerFor('a');
      await player.removeSources(<String>['a']);

      expect(controller.isReleased, isTrue);
      expect(player.sources.map((FeedSource s) => s.id), <String>['b']);
    });

    test('player dispose releases every outstanding controller', () async {
      final FeedController a = await player.controllerFor('a');
      final FeedController b = await player.controllerFor('b');

      await player.dispose();

      expect(a.isReleased, isTrue);
      expect(b.isReleased, isTrue);
      expect(player.activeControllers, isEmpty);
    });
  });
}
