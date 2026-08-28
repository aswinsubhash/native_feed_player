import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_feed_player/native_feed_player.dart';

import 'support/recording_platform.dart';

void main() {
  late RecordingFeedPlayerPlatform platform;
  late FeedPlayer player;

  setUp(() async {
    platform = RecordingFeedPlayerPlatform();
    player = FeedPlayer(platform: platform);
    await player.initialize();
    await player.setSources(<FeedSource>[
      const FeedSource(id: 'a', uri: 'https://example.test/a.mp4'),
      const FeedSource(id: 'b', uri: 'https://example.test/b.mp4'),
    ]);
  });

  tearDown(() async {
    await platform.close();
  });

  Future<Widget> wrap(FeedController controller, {BoxFit? fit}) async {
    return MaterialApp(
      home: NativeVideoView(
        controller: controller,
        renderMode: RenderMode.texture,
        fit: fit,
        placeholder: const Text('poster'),
      ),
    );
  }

  testWidgets('attaches a texture and renders it', (WidgetTester tester) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(controller));
    await tester.pump();

    expect(platform.attachedTextureControllerIds, <int>[
      controller.controllerId,
    ]);
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('shows the placeholder until the first frame', (
    WidgetTester tester,
  ) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(controller));
    await tester.pump();

    expect(find.text('poster'), findsOneWidget);

    platform.emitMetrics(
      controllerId: controller.controllerId,
      firstFrameLatencyMs: 120,
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('poster'),
      findsNothing,
      reason: 'the poster must disappear once a frame is actually rendered',
    );
  });

  testWidgets('sizes the surface from the reported video size', (
    WidgetTester tester,
  ) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(controller));
    await tester.pump();

    platform.emitVideoSize(
      controllerId: controller.controllerId,
      width: 1080,
      height: 1920,
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(FittedBox),
      findsOneWidget,
      reason: 'a known size switches the surface to fit-based sizing',
    );
    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);
    final Iterable<SizedBox> sized = tester.widgetList<SizedBox>(
      find.byType(SizedBox),
    );
    expect(
      sized.any((SizedBox box) => box.width == 1080 && box.height == 1920),
      isTrue,
      reason: 'the surface is sized to the reported video dimensions',
    );
  });

  testWidgets('adaptive fit contains landscape videos', (
    WidgetTester tester,
  ) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(controller));
    await tester.pump();

    platform.emitVideoSize(
      controllerId: controller.controllerId,
      width: 1920,
      height: 1080,
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<FittedBox>(find.byType(FittedBox)).fit,
      BoxFit.contain,
    );
  });

  testWidgets('adaptive fit accounts for rotated portrait videos', (
    WidgetTester tester,
  ) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(controller));
    await tester.pump();

    platform.emitVideoSize(
      controllerId: controller.controllerId,
      width: 1920,
      height: 1080,
      rotationDegrees: 90,
    );
    await tester.pump();
    await tester.pump();

    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);
    final Iterable<SizedBox> sized = tester.widgetList<SizedBox>(
      find.byType(SizedBox),
    );
    expect(
      sized.any((SizedBox box) => box.width == 1080 && box.height == 1920),
      isTrue,
    );
  });

  testWidgets('explicit fit overrides adaptive landscape sizing', (
    WidgetTester tester,
  ) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(controller, fit: BoxFit.cover));
    await tester.pump();

    platform.emitVideoSize(
      controllerId: controller.controllerId,
      width: 1920,
      height: 1080,
    );
    await tester.pump();
    await tester.pump();

    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);
  });

  testWidgets('swapping controllers detaches the old texture', (
    WidgetTester tester,
  ) async {
    final FeedController first = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(first));
    await tester.pump();

    final FeedController second = await player.controllerFor('b');
    await tester.pumpWidget(await wrap(second));
    await tester.pump();
    await tester.pump();

    expect(platform.detachedTextureControllerIds, contains(first.controllerId));
    expect(platform.attachedTextureControllerIds, <int>[
      first.controllerId,
      second.controllerId,
    ]);
  });

  testWidgets('disposal detaches the texture', (WidgetTester tester) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(await wrap(controller));
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(platform.detachedTextureControllerIds, <int>[
      controller.controllerId,
    ]);
  });

  testWidgets('a released controller is never attached', (
    WidgetTester tester,
  ) async {
    final FeedController controller = await player.controllerFor('a');
    platform.emitRelease(
      controllerId: controller.controllerId,
      reason: ControllerReleaseReason.evicted,
    );
    await controller.onReleased;

    await tester.pumpWidget(await wrap(controller));
    await tester.pump();

    expect(platform.attachedTextureControllerIds, isEmpty);
  });

  testWidgets('adaptive fit is forwarded to the iOS platform view', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final FeedController controller = await player.controllerFor('a');
      await tester.pumpWidget(
        MaterialApp(
          home: NativeVideoView(
            controller: controller,
            renderMode: RenderMode.platformView,
          ),
        ),
      );
      await tester.pump();

      platform.emitVideoSize(
        controllerId: controller.controllerId,
        width: 1920,
        height: 1080,
      );
      await tester.pump();
      await tester.pump();

      final UiKitView view = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(view.creationParams, <String, Object>{'fit': 'contain'});
      expect(view.key, const ValueKey<BoxFit>(BoxFit.contain));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('platform-view mode does not request a texture', (
    WidgetTester tester,
  ) async {
    final FeedController controller = await player.controllerFor('a');
    await tester.pumpWidget(
      MaterialApp(
        home: NativeVideoView(
          controller: controller,
          renderMode: RenderMode.platformView,
        ),
      ),
    );
    await tester.pump();

    expect(platform.attachedTextureControllerIds, isEmpty);
    expect(find.byType(Texture), findsNothing);
  });
}
