import 'package:flutter_test/flutter_test.dart';
import 'package:native_reels_player/native_reels_player.dart';
import 'package:native_reels_player/native_reels_player_platform_interface.dart';
import 'package:native_reels_player/native_reels_player_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNativeReelsPlayerPlatform
    with MockPlatformInterfaceMixin
    implements NativeReelsPlayerPlatform {
  bool initializeCalled = false;
  List<NativeVideoSource> preloadSources = <NativeVideoSource>[];

  @override
  Future<void> initialize({required NativeReelsConfig config}) async {
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
    return index + 1;
  }

  @override
  Future<void> disposeController(int controllerId) async {}

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
  final NativeReelsPlayerPlatform initialPlatform =
      NativeReelsPlayerPlatform.instance;

  test('$MethodChannelNativeReelsPlayer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNativeReelsPlayer>());
  });

  test('initialize and preload', () async {
    final MockNativeReelsPlayerPlatform fakePlatform =
        MockNativeReelsPlayerPlatform();
    final NativeReelsPlayer player = NativeReelsPlayer(platform: fakePlatform);

    await player.initialize();
    await player.preload(<String>['u1', 'u2']);

    expect(fakePlatform.initializeCalled, isTrue);
    expect(fakePlatform.preloadSources.length, 2);
    expect(fakePlatform.preloadSources.first.url, 'u1');
  });
}
