// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:native_reels_player/native_reels_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String goodUrlA =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';
  const String goodUrlB =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4';
  const String unreachableUrl = 'https://127.0.0.1:9/offline.mp4';

  testWidgets('initialize and create controller', (WidgetTester tester) async {
    final NativeReelsPlayer plugin = NativeReelsPlayer();
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
    final NativeReelsPlayer plugin = NativeReelsPlayer();
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
      controllerIds.add(controller.controllerId);
    }

    expect(controllerIds.toSet().length, urls.length);
    await plugin.dispose();
  });

  testWidgets('pause/resume lifecycle keeps controller commands usable', (
    WidgetTester tester,
  ) async {
    final NativeReelsPlayer plugin = NativeReelsPlayer();
    await plugin.initialize();
    await plugin.preload(<String>[goodUrlA]);
    final VideoController controller = await plugin.getController(
      url: goodUrlA,
      index: 0,
    );

    await controller.play();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 300));
    await controller.pause();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    await controller.play();

    expect(controller.controllerId, greaterThan(0));
    await plugin.dispose();
  });

  testWidgets(
    'network loss and recovery path creates new playable controller',
    (WidgetTester tester) async {
      final NativeReelsPlayer plugin = NativeReelsPlayer();
      await plugin.initialize();
      await plugin.preload(<String>[unreachableUrl, goodUrlB]);

      final VideoController badController = await plugin.getController(
        url: unreachableUrl,
        index: 0,
        autoPlay: true,
      );
      await badController.play();
      await tester.pump(const Duration(milliseconds: 600));

      final VideoController recoveredController = await plugin.getController(
        url: goodUrlB,
        index: 1,
        autoPlay: true,
      );
      await recoveredController.play();

      expect(recoveredController.controllerId, greaterThan(0));
      expect(
        recoveredController.controllerId,
        isNot(badController.controllerId),
      );
      await plugin.dispose();
    },
  );
}
