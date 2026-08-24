import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_feed_player/native_feed_player.dart';
import 'package:native_feed_player/native_feed_player_method_channel.dart';
import 'package:native_feed_player/native_feed_player_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNativeFeedPlayerPlatform
    with MockPlatformInterfaceMixin
    implements NativeFeedPlayerPlatform {
  MockNativeFeedPlayerPlatform();

  final StreamController<ControllerReleaseEvent> releaseController =
      StreamController<ControllerReleaseEvent>.broadcast();
  final List<int> disposedControllerIds = <int>[];

  bool initializeCalled = false;
  List<NativeVideoSource> preloadSources = <NativeVideoSource>[];
  int nextControllerId = 1;

  @override
  Stream<ControllerReleaseEvent> get releaseEvents => releaseController.stream;

  @override
  Future<void> initialize({required NativeFeedConfig config}) async {
    initializeCalled = true;
  }

  @override
  Future<void> preload(List<NativeVideoSource> sources) async {
    preloadSources = sources;
  }

  @override
  Future<int> createController({
    required String url,
    required int index,
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
  Stream<Duration> positionStream(int controllerId) => const Stream.empty();

  @override
  Stream<VideoPlaybackState> stateStream(int controllerId) =>
      const Stream.empty();

  @override
  Stream<VideoMetrics> metricsStream(int controllerId) => const Stream.empty();

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> setVisibleIndex(int index) async {}

  @override
  Future<void> attachView({
    required int controllerId,
    required int viewId,
  }) async {}

  @override
  Future<void> detachView({required int controllerId}) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  final NativeFeedPlayerPlatform initialPlatform =
      NativeFeedPlayerPlatform.instance;

  test('$MethodChannelNativeFeedPlayer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNativeFeedPlayer>());
  });

  test('initialize and preload', () async {
    final MockNativeFeedPlayerPlatform fakePlatform =
        MockNativeFeedPlayerPlatform();
    final NativeFeedPlayer player = NativeFeedPlayer(platform: fakePlatform);

    await player.initialize();
    await player.preload(<String>['u1', 'u2']);

    expect(fakePlatform.initializeCalled, isTrue);
    expect(fakePlatform.preloadSources.length, 2);
    expect(fakePlatform.preloadSources.first.url, 'u1');
  });

  group('native release reconciliation', () {
    late MockNativeFeedPlayerPlatform platform;
    late NativeFeedPlayer player;

    setUp(() async {
      platform = MockNativeFeedPlayerPlatform();
      player = NativeFeedPlayer(platform: platform);
      await player.initialize();
    });

    tearDown(() async {
      await platform.releaseController.close();
    });

    test('eviction purges the controller cache', () async {
      final VideoController controller = await player.getController(
        url: 'u1',
        index: 0,
      );
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

    test('getController creates a fresh controller after eviction', () async {
      final VideoController first = await player.getController(
        url: 'u1',
        index: 0,
      );
      platform.releaseController.add(
        ControllerReleaseEvent(
          controllerId: first.controllerId,
          reason: ControllerReleaseReason.evicted,
        ),
      );
      await first.onReleased;

      final VideoController second = await player.getController(
        url: 'u1',
        index: 0,
      );

      expect(second.controllerId, isNot(first.controllerId));
      expect(second.isReleased, isFalse);
    });

    test('commands on a released controller throw', () async {
      final VideoController controller = await player.getController(
        url: 'u1',
        index: 0,
      );
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
      final VideoController controller = await player.getController(
        url: 'u1',
        index: 0,
      );

      await controller.dispose();
      await controller.dispose();

      expect(platform.disposedControllerIds, <int>[controller.controllerId]);
      expect(player.activeControllers, isEmpty);
      expect(controller.releaseReason, ControllerReleaseReason.disposed);
    });

    test('player dispose releases every outstanding controller', () async {
      final VideoController a = await player.getController(url: 'u1', index: 0);
      final VideoController b = await player.getController(url: 'u2', index: 1);

      await player.dispose();

      expect(a.isReleased, isTrue);
      expect(b.isReleased, isTrue);
      expect(player.activeControllers, isEmpty);
    });
  });
}
