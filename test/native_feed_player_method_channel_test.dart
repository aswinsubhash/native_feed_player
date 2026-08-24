import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_feed_player/native_feed_player_method_channel.dart';
import 'package:native_feed_player/src/messages.g.dart';
import 'package:native_feed_player/src/video_metrics.dart';
import 'package:native_feed_player/src/video_models.dart';

class FakeNativeFeedPlayerHostApi extends NativeFeedPlayerHostApi {
  int nextControllerId = 7;
  InitializeRequest? initializeRequest;
  PreloadRequest? preloadRequest;
  CreateControllerRequest? createRequest;

  @override
  Future<void> attachView(AttachViewRequest request) async {}

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> createController(CreateControllerRequest request) async {
    createRequest = request;
    return nextControllerId;
  }

  @override
  Future<void> detachView(ControllerRequest request) async {}

  @override
  Future<void> disposeAll() async {}

  @override
  Future<void> disposeController(ControllerRequest request) async {}

  @override
  Future<void> initialize(InitializeRequest request) async {
    initializeRequest = request;
  }

  @override
  Future<void> pause(ControllerRequest request) async {}

  @override
  Future<void> play(ControllerRequest request) async {}

  @override
  Future<void> preload(PreloadRequest request) async {
    preloadRequest = request;
  }

  @override
  Future<void> seekTo(SeekRequest request) async {}

  @override
  Future<void> setVisibleIndex(VisibleIndexRequest request) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel metricsChannel = MethodChannel(
    'native_feed_player/metrics',
  );
  const StandardMethodCodec codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeNativeFeedPlayerHostApi fakeHostApi;
  late MethodChannelNativeFeedPlayer platform;

  setUp(() {
    fakeHostApi = FakeNativeFeedPlayerHostApi();
    platform = MethodChannelNativeFeedPlayer(hostApi: fakeHostApi);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(metricsChannel, (
          MethodCall methodCall,
        ) async {
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(metricsChannel, null);
  });

  test('initialize', () async {
    await platform.initialize(config: const NativeFeedConfig());

    expect(fakeHostApi.initializeRequest, isNotNull);
    expect(fakeHostApi.initializeRequest!.maxCachedPlayers, 5);
    expect(fakeHostApi.initializeRequest!.preloadCount, 2);
  });

  test('createController returns id', () async {
    final int id = await platform.createController(
      url: 'u',
      index: 0,
      autoPlay: false,
      looping: true,
    );

    expect(id, 7);
    expect(fakeHostApi.createRequest, isNotNull);
    expect(fakeHostApi.createRequest!.url, 'u');
    expect(fakeHostApi.createRequest!.index, 0);
    expect(fakeHostApi.createRequest!.autoPlay, isFalse);
    expect(fakeHostApi.createRequest!.looping, isTrue);
  });

  test('metrics stream maps native payload', () async {
    final Future<VideoMetrics> nextMetric = platform.metricsStream(7).first;
    await messenger.handlePlatformMessage(
      'native_feed_player/metrics',
      codec.encodeSuccessEnvelope(<String, Object?>{
        'controllerId': 7,
        'rebufferCount': 2,
        'droppedFramesEstimate': 5,
        'firstFrameLatencyMs': 140,
        'timestampMs': 1234,
      }),
      (_) {},
    );

    final VideoMetrics metric = await nextMetric;
    expect(metric.controllerId, 7);
    expect(metric.rebufferCount, 2);
    expect(metric.droppedFramesEstimate, 5);
    expect(metric.firstFrameLatency, const Duration(milliseconds: 140));
    expect(metric.timestamp, DateTime.fromMillisecondsSinceEpoch(1234));
  });
}
