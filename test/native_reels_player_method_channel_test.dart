import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_reels_player/native_reels_player_method_channel.dart';
import 'package:native_reels_player/src/video_models.dart';
import 'package:native_reels_player/src/video_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelNativeReelsPlayer platform =
      MethodChannelNativeReelsPlayer();
  const MethodChannel channel = MethodChannel('native_reels_player');
  const MethodChannel stateChannel = MethodChannel('native_reels_player/state');
  const MethodChannel positionChannel = MethodChannel(
    'native_reels_player/position',
  );
  const MethodChannel metricsChannel = MethodChannel(
    'native_reels_player/metrics',
  );
  const StandardMethodCodec codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'createController') {
            return 7;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(stateChannel, (MethodCall methodCall) async {
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(positionChannel, (
          MethodCall methodCall,
        ) async {
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(metricsChannel, (
          MethodCall methodCall,
        ) async {
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(stateChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(positionChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(metricsChannel, null);
  });

  test('initialize', () async {
    await platform.initialize(config: const NativeReelsConfig());
  });

  test('createController returns id', () async {
    final int id = await platform.createController(
      url: 'u',
      index: 0,
      autoPlay: false,
      looping: true,
    );
    expect(id, 7);
  });

  test('metrics stream maps native payload', () async {
    final Future<VideoMetrics> nextMetric = platform.metricsStream(7).first;
    await messenger.handlePlatformMessage(
      'native_reels_player/metrics',
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
