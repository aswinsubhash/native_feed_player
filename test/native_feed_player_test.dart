import 'dart:async';

import 'package:flutter/foundation.dart';
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
  Completer<void>? initializeGate;
  Completer<void>? setSourcesGate;
  Completer<void>? appendSourcesGate;
  Completer<void>? removeSourcesGate;
  Completer<int>? createControllerGate;
  Completer<void>? disposeControllerGate;
  Completer<void>? audioPolicyGate;
  Completer<void>? disposeGate;
  Object? initializeError;
  Object? setSourcesError;
  Object? removeSourcesError;
  Object? disposeControllerError;
  Object? audioPolicyError;
  Object? disposeError;
  int nextControllerId = 1;
  int createControllerCalls = 0;

  @override
  Stream<ControllerReleaseEvent> get releaseEvents => releaseController.stream;

  @override
  Future<void> initialize(FeedPlayerConfig config) async {
    await initializeGate?.future;
    final Object? error = initializeError;
    if (error != null) {
      throw error;
    }
    initializedWith = config;
  }

  @override
  Future<void> setSources(List<FeedSource> sources) async {
    setSourceCalls.add(sources);
    await setSourcesGate?.future;
    final Object? error = setSourcesError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> appendSources(
    List<FeedSource> sources, {
    required int rankOffset,
  }) async {
    appendCalls.add((sources, rankOffset));
    await appendSourcesGate?.future;
  }

  @override
  Future<void> removeSources(List<String> sourceIds) async {
    await removeSourcesGate?.future;
    final Object? error = removeSourcesError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<int> createController({
    required String sourceId,
    required bool autoPlay,
    required bool looping,
  }) async {
    createControllerCalls += 1;
    final Completer<int>? gate = createControllerGate;
    if (gate != null) {
      return gate.future;
    }
    return nextControllerId++;
  }

  @override
  Future<void> disposeController(int controllerId) async {
    disposedControllerIds.add(controllerId);
    await disposeControllerGate?.future;
    final Object? error = disposeControllerError;
    if (error != null) {
      throw error;
    }
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
    await audioPolicyGate?.future;
    final Object? error = audioPolicyError;
    if (error != null) {
      throw error;
    }
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
  Future<void> dispose() async {
    await disposeGate?.future;
    final Object? error = disposeError;
    if (error != null) {
      throw error;
    }
  }
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
      expect(config.audio.muted, isFalse);
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

    test('removing sources republishes dense ranks before appending', () async {
      await player.setSources(<FeedSource>[
        _source('a'),
        _source('b'),
        _source('c'),
      ]);

      await player.removeSources(<String>['b']);
      expect(
        platform.setSourceCalls.last.map((FeedSource source) => source.id),
        <String>['a', 'c'],
      );

      await player.appendSources(<FeedSource>[_source('d')]);
      expect(platform.appendCalls.single.$2, 2);
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
      await expectLater(
        player.appendSources(<FeedSource>[_source('a')]),
        throwsArgumentError,
      );
    });

    test('controllerFor requires a registered source', () async {
      await expectLater(player.controllerFor('missing'), throwsArgumentError);
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

    test('invalid volume is rejected before it reaches the platform', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController controller = await player.controllerFor('a');

      expect(() => controller.setVolume(3.2), throwsArgumentError);
      expect(() => controller.setVolume(-1), throwsArgumentError);
      expect(() => controller.setVolume(double.nan), throwsArgumentError);
      expect(() => controller.setVolume(double.infinity), throwsArgumentError);

      expect(platform.volumeCalls, isEmpty);
    });

    test(
      'invalid playback speed is rejected before it reaches the platform',
      () async {
        await player.setSources(<FeedSource>[_source('a')]);
        final FeedController controller = await player.controllerFor('a');

        expect(() => controller.setPlaybackSpeed(0), throwsArgumentError);
        expect(() => controller.setPlaybackSpeed(-1.5), throwsArgumentError);
        expect(
          () => controller.setPlaybackSpeed(double.nan),
          throwsArgumentError,
        );
        expect(
          () => controller.setPlaybackSpeed(double.infinity),
          throwsArgumentError,
        );

        expect(platform.speedCalls, isEmpty);
      },
    );

    test('setMuted updates the retained audio policy', () async {
      expect(player.config.audio.muted, isFalse);

      await player.setMuted(true);

      expect(platform.audioPolicies.single.muted, isTrue);
      expect(player.config.audio.muted, isTrue);
      expect(player.config.maxActivePlayers, 3);
      expect(player.config.cache.maxBytes, 256 * 1024 * 1024);
    });

    test('queued mute retains earlier audio policy updates', () async {
      final Completer<void> gate = Completer<void>();
      platform.audioPolicyGate = gate;

      final Future<void> volumeUpdate = player.setAudioPolicy(
        const AudioPolicy(volume: 0.25),
      );
      final Future<void> muteUpdate = player.setMuted(true);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait(<Future<void>>[volumeUpdate, muteUpdate]);

      expect(platform.audioPolicies, hasLength(2));
      expect(platform.audioPolicies.last.volume, 0.25);
      expect(platform.audioPolicies.last.muted, isTrue);
    });

    test('initialize replaces the previous session', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController controller = await player.controllerFor('a');

      await player.initialize();

      expect(controller.isReleased, isTrue);
      expect(controller.releaseReason, ControllerReleaseReason.disposed);
      expect(player.sources, isEmpty);
      expect(player.activeControllers, isEmpty);
    });

    test('visible source must be registered', () async {
      await player.setSources(<FeedSource>[_source('a')]);

      await expectLater(
        player.setVisibleSource('missing'),
        throwsArgumentError,
      );
      expect(platform.visibleSourceIds, isEmpty);
    });

    test('empty source ids and uris are rejected before platform calls', () {
      expect(
        () => player.setSources(const <FeedSource>[
          FeedSource(id: ' ', uri: 'a.mp4'),
        ]),
        throwsArgumentError,
      );
      expect(
        () => player.setSources(const <FeedSource>[
          FeedSource(id: 'a', uri: ' '),
        ]),
        throwsArgumentError,
      );
      expect(platform.setSourceCalls, isEmpty);
    });

    test('source mutations are serialized in invocation order', () async {
      platform.setSourcesGate = Completer<void>();

      final Future<void> set = player.setSources(<FeedSource>[_source('a')]);
      final Future<void> append = player.appendSources(<FeedSource>[
        _source('b'),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(platform.setSourceCalls, hasLength(1));
      expect(platform.appendCalls, isEmpty);

      platform.setSourcesGate!.complete();
      await set;
      await append;

      expect(platform.appendCalls.single.$2, 1);
      expect(player.sources.map((FeedSource source) => source.id), <String>[
        'a',
        'b',
      ]);
    });

    test('failed source replacement does not commit local state', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      platform.setSourcesError = StateError('set failed');

      await expectLater(
        player.setSources(<FeedSource>[_source('b')]),
        throwsStateError,
      );

      expect(player.sources.map((FeedSource source) => source.id), <String>[
        'a',
      ]);

      await player.appendSources(<FeedSource>[_source('b')]);
      expect(player.sources.map((FeedSource source) => source.id), <String>[
        'a',
        'b',
      ]);
    });

    test('failed removal preserves sources and controllers', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController controller = await player.controllerFor('a');
      platform.setSourcesError = StateError('remove failed');

      await expectLater(player.removeSources(<String>['a']), throwsStateError);

      expect(player.sources, hasLength(1));
      expect(controller.isReleased, isFalse);
      expect(player.activeControllers, contains(controller));
    });

    test('failed audio update preserves the retained policy', () async {
      platform.audioPolicyError = StateError('audio failed');

      await expectLater(
        player.setAudioPolicy(const AudioPolicy(muted: true, volume: 0.25)),
        throwsStateError,
      );

      expect(player.config.audio.muted, isFalse);
      expect(player.config.audio.volume, 1.0);
    });

    test('failed reinitialize invalidates the current session', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController controller = await player.controllerFor('a');
      platform.initializeError = StateError('initialize failed');

      await expectLater(
        player.initialize(config: const FeedPlayerConfig(maxActivePlayers: 5)),
        throwsStateError,
      );

      expect(player.config.maxActivePlayers, 3);
      expect(player.sources, isEmpty);
      expect(controller.isReleased, isTrue);
      expect(() => player.setSources(<FeedSource>[]), throwsStateError);
    });

    test('overlapping controller requests share one creation', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      platform.createControllerGate = Completer<int>();

      final Future<FeedController> first = player.controllerFor('a');
      final Future<FeedController> second = player.controllerFor('a');
      await Future<void>.delayed(Duration.zero);

      expect(platform.createControllerCalls, 1);
      platform.createControllerGate!.complete(42);

      expect(identical(await first, await second), isTrue);
      expect(platform.createControllerCalls, 1);
    });

    test('failed controller creation does not populate the cache', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final Completer<int> creation = Completer<int>();
      platform.createControllerGate = creation;

      final Future<FeedController> controller = player.controllerFor('a');
      final Future<void> expectation = expectLater(
        controller,
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      creation.completeError(StateError('create failed'));
      await expectation;

      expect(player.activeControllers, isEmpty);
      platform.createControllerGate = null;
      expect((await player.controllerFor('a')).isReleased, isFalse);
    });

    test(
      'replacing source metadata releases its existing controller',
      () async {
        await player.setSources(<FeedSource>[
          const FeedSource(
            id: 'a',
            uri: 'https://example.test/a.mp4',
            headers: <String, String>{'Authorization': 'first'},
          ),
        ]);
        final FeedController controller = await player.controllerFor('a');

        await player.setSources(<FeedSource>[
          const FeedSource(
            id: 'a',
            uri: 'https://example.test/a.mp4',
            headers: <String, String>{'Authorization': 'second'},
          ),
        ]);

        expect(platform.disposedControllerIds, isEmpty);
        expect(controller.isReleased, isTrue);
        expect(player.activeControllers, isEmpty);
      },
    );

    test('dispose remains terminal when platform disposal fails', () async {
      await player.setSources(<FeedSource>[_source('a')]);
      final FeedController controller = await player.controllerFor('a');
      platform.disposeError = StateError('dispose failed');

      await expectLater(player.dispose(), throwsStateError);

      expect(controller.isReleased, isTrue);
      expect(player.sources, isEmpty);
      expect(() => player.initialize(), throwsStateError);
      expect(() => player.setSources(<FeedSource>[]), throwsStateError);
      await expectLater(player.dispose(), throwsStateError);
    });

    test('uninitialized use is rejected', () async {
      final FeedPlayer fresh = FeedPlayer(platform: FakeFeedPlayerPlatform());
      await expectLater(fresh.setSources(<FeedSource>[]), throwsStateError);
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

    test(
      'a delayed release event cannot release a replacement controller',
      () async {
        final FeedController first = await player.controllerFor('a');
        await first.dispose();
        final FeedController replacement = await player.controllerFor('a');

        platform.releaseController.add(
          ControllerReleaseEvent(
            controllerId: first.controllerId,
            reason: ControllerReleaseReason.evicted,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(replacement.isReleased, isFalse);
        expect(player.activeControllers, contains(replacement));
      },
    );

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

    test('failed controller disposal does not mark it released', () async {
      final FeedController controller = await player.controllerFor('a');
      platform.disposeControllerError = StateError('dispose failed');

      await expectLater(controller.dispose(), throwsStateError);

      expect(controller.isReleased, isFalse);
      expect(player.activeControllers, contains(controller));
      platform.disposeControllerError = null;
      await controller.dispose();
      expect(controller.isReleased, isTrue);
    });

    test(
      'overlapping controller disposal uses one platform operation',
      () async {
        final FeedController controller = await player.controllerFor('a');
        final Completer<void> gate = Completer<void>();
        platform.disposeControllerGate = gate;

        final Future<void> first = controller.dispose();
        final Future<void> second = controller.dispose();
        await Future<void>.delayed(Duration.zero);

        expect(platform.disposedControllerIds, <int>[controller.controllerId]);
        gate.complete();
        await Future.wait(<Future<void>>[first, second]);
        expect(controller.isReleased, isTrue);
      },
    );

    test('controllerFor waits for an in-flight disposal', () async {
      final FeedController controller = await player.controllerFor('a');
      final Completer<void> gate = Completer<void>();
      platform.disposeControllerGate = gate;

      final Future<void> disposal = controller.dispose();
      final Future<FeedController> replacementFuture = player.controllerFor(
        'a',
      );
      await Future<void>.delayed(Duration.zero);

      expect(platform.createControllerCalls, 1);
      gate.complete();
      await disposal;
      final FeedController replacement = await replacementFuture;

      expect(identical(replacement, controller), isFalse);
      expect(platform.createControllerCalls, 2);
    });

    test('controllerFor reuses a controller whose disposal failed', () async {
      final FeedController controller = await player.controllerFor('a');
      final Completer<void> gate = Completer<void>();
      platform.disposeControllerGate = gate;
      platform.disposeControllerError = StateError('dispose failed');

      final Future<void> disposal = controller.dispose();
      final Future<FeedController> controllerFuture = player.controllerFor('a');
      await Future<void>.delayed(Duration.zero);
      gate.complete();

      await expectLater(disposal, throwsStateError);
      expect(await controllerFuture, same(controller));
      expect(platform.createControllerCalls, 1);
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

  group('FeedPlayer stream errors', () {
    late FakeFeedPlayerPlatform platform;
    late FeedPlayer player;
    final List<FlutterErrorDetails> reported = <FlutterErrorDetails>[];
    void Function(FlutterErrorDetails)? previousHandler;

    setUp(() {
      platform = FakeFeedPlayerPlatform();
      previousHandler = FlutterError.onError;
      reported.clear();
      FlutterError.onError = (FlutterErrorDetails details) {
        reported.add(details);
      };
      player = FeedPlayer(platform: platform);
    });

    tearDown(() async {
      FlutterError.onError = previousHandler;
      await platform.releaseController.close();
    });

    test('lifecycle stream errors are reported, not unhandled', () async {
      final Object error = StateError('lifecycle channel failed');

      platform.releaseController.addError(error);
      await Future<void>.delayed(Duration.zero);

      expect(reported, hasLength(1));
      expect(reported.single.exception, same(error));
      expect(reported.single.library, 'native_feed_player');
      // The player remains usable after a stream error.
      await player.initialize();
      expect(player.config.maxActivePlayers, 3);
    });
  });
}
