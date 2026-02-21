import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_reels_player/native_reels_player_method_channel.dart';
import 'package:native_reels_player/src/video_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelNativeReelsPlayer platform =
      MethodChannelNativeReelsPlayer();
  const MethodChannel channel = MethodChannel('native_reels_player');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'createController') {
            return 7;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
}
