import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_feed_player/native_feed_player.dart';
import 'package:native_feed_player/native_feed_player_method_channel.dart';
import 'package:native_feed_player/src/messages.g.dart';

class FakeHostApi extends NativeFeedPlayerHostApi {
  FeedPlayerConfigMessage? initializeRequest;
  List<FeedSourceMessage>? setSourcesRequest;
  List<FeedSourceMessage>? appendSourcesRequest;
  CreateControllerRequest? createRequest;
  VisibleSourceRequest? visibleRequest;
  SourceIdsRequest? evictRequest;
  bool clearedCache = false;
  int nextControllerId = 7;

  @override
  Future<void> initialize(FeedPlayerConfigMessage config) async {
    initializeRequest = config;
  }

  @override
  Future<void> setSources(List<FeedSourceMessage> sources) async {
    setSourcesRequest = sources;
  }

  @override
  Future<void> appendSources(List<FeedSourceMessage> sources) async {
    appendSourcesRequest = sources;
  }

  @override
  Future<void> removeSources(SourceIdsRequest request) async {}

  @override
  Future<int> createController(CreateControllerRequest request) async {
    createRequest = request;
    return nextControllerId;
  }

  @override
  Future<void> disposeController(ControllerRequest request) async {}

  @override
  Future<void> play(ControllerRequest request) async {}

  @override
  Future<void> pause(ControllerRequest request) async {}

  @override
  Future<void> seekTo(SeekRequest request) async {}

  @override
  Future<void> setVisibleSource(VisibleSourceRequest request) async {
    visibleRequest = request;
  }

  @override
  Future<void> evictCachedMedia(SourceIdsRequest request) async {
    evictRequest = request;
  }

  @override
  Future<void> clearMediaCache() async {
    clearedCache = true;
  }

  @override
  Future<CacheStatusMessage> cacheStatus(VisibleSourceRequest request) async {
    return CacheStatusMessage(
      sourceId: request.sourceId,
      cachedBytes: 512,
      totalBytes: 2048,
      isComplete: false,
    );
  }

  @override
  Future<int> cacheUsageBytes() async => 4096;

  @override
  Future<void> attachView(AttachViewRequest request) async {}

  @override
  Future<void> detachView(ControllerRequest request) async {}

  @override
  Future<void> disposeAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHostApi hostApi;
  late StreamController<PlaybackStateEvent> states;
  late StreamController<PositionEvent> positions;
  late StreamController<MetricsEvent> metrics;
  late StreamController<VideoSizeEvent> videoSizes;
  late StreamController<ControllerLifecycleEvent> lifecycle;
  late MethodChannelFeedPlayer platform;

  setUp(() {
    hostApi = FakeHostApi();
    states = StreamController<PlaybackStateEvent>.broadcast();
    positions = StreamController<PositionEvent>.broadcast();
    metrics = StreamController<MetricsEvent>.broadcast();
    videoSizes = StreamController<VideoSizeEvent>.broadcast();
    lifecycle = StreamController<ControllerLifecycleEvent>.broadcast();
    platform = MethodChannelFeedPlayer(
      hostApi: hostApi,
      playbackStateEventStream: states.stream,
      positionEventStream: positions.stream,
      metricsEventStream: metrics.stream,
      videoSizeEventStream: videoSizes.stream,
      lifecycleEventStream: lifecycle.stream,
    );
  });

  tearDown(() async {
    await states.close();
    await positions.close();
    await metrics.close();
    await videoSizes.close();
    await lifecycle.close();
  });

  test('initialize forwards the whole config', () async {
    await platform.initialize(
      const FeedPlayerConfig(
        maxActivePlayers: 4,
        preloadAhead: 3,
        preloadBehind: 1,
        maxConcurrentPreloads: 5,
        positionUpdateInterval: Duration(milliseconds: 250),
        renderMode: RenderMode.texture,
        cache: CachePolicy(enabled: false, maxBytes: 1024),
        audio: AudioPolicy(muted: false, volume: 0.5, handleAudioFocus: false),
      ),
    );

    final FeedPlayerConfigMessage config = hostApi.initializeRequest!;
    expect(config.maxActivePlayers, 4);
    expect(config.preloadAhead, 3);
    expect(config.preloadBehind, 1);
    expect(config.maxConcurrentPreloads, 5);
    expect(config.positionUpdateIntervalMs, 250);
    expect(config.renderMode, RenderModeMessage.texture);
    expect(config.cache.enabled, isFalse);
    expect(config.cache.maxBytes, 1024);
    expect(config.audio.muted, isFalse);
    expect(config.audio.volume, 0.5);
    expect(config.audio.handleAudioFocus, isFalse);
  });

  test('setSources assigns sequential ranks', () async {
    await platform.setSources(<FeedSource>[
      const FeedSource(id: 'a', uri: 'https://example.test/a.mp4'),
      const FeedSource(id: 'b', uri: 'https://example.test/b.mp4'),
    ]);

    expect(
      hostApi.setSourcesRequest!.map((FeedSourceMessage m) => (m.id, m.rank)),
      <(String, int)>[('a', 0), ('b', 1)],
    );
  });

  test('appendSources continues ranks from the offset', () async {
    await platform.appendSources(<FeedSource>[
      const FeedSource(id: 'c', uri: 'https://example.test/c.mp4'),
      const FeedSource(id: 'd', uri: 'https://example.test/d.mp4'),
    ], rankOffset: 5);

    expect(
      hostApi.appendSourcesRequest!.map(
        (FeedSourceMessage m) => (m.id, m.rank),
      ),
      <(String, int)>[('c', 5), ('d', 6)],
    );
  });

  test('source headers and kind survive the round trip', () async {
    await platform.setSources(<FeedSource>[
      const FeedSource(
        id: 'a',
        uri: 'https://example.test/a.m3u8',
        kind: FeedMediaKind.hls,
        headers: <String, String>{'Authorization': 'Bearer token'},
      ),
    ]);

    final FeedSourceMessage message = hostApi.setSourcesRequest!.single;
    expect(message.kind, FeedMediaKindMessage.hls);
    expect(message.headers['Authorization'], 'Bearer token');
  });

  test('createController returns the native id', () async {
    final int id = await platform.createController(
      sourceId: 'a',
      autoPlay: false,
      looping: true,
    );

    expect(id, 7);
    expect(hostApi.createRequest!.sourceId, 'a');
    expect(hostApi.createRequest!.autoPlay, isFalse);
    expect(hostApi.createRequest!.looping, isTrue);
  });

  test('state stream is filtered per controller and carries errors', () async {
    final Future<PlaybackStatusUpdate> next = platform.stateStream(7).first;

    states.add(
      PlaybackStateEvent(
        controllerId: 99,
        status: PlaybackStatusMessage.playing,
      ),
    );
    states.add(
      PlaybackStateEvent(
        controllerId: 7,
        status: PlaybackStatusMessage.error,
        error: PlaybackErrorMessage(
          code: 'network_failed',
          message: 'offline',
          isRecoverable: true,
          platformCode: 'NSURLErrorDomain:-1009',
        ),
      ),
    );

    final PlaybackStatusUpdate update = await next;
    expect(update.state, VideoPlaybackState.error);
    expect(update.error!.code, 'network_failed');
    expect(update.error!.isRecoverable, isTrue);
    expect(update.error!.platformCode, 'NSURLErrorDomain:-1009');
  });

  test('late state subscriber receives the latest update', () async {
    await platform.initialize(const FeedPlayerConfig());
    states.add(
      PlaybackStateEvent(
        controllerId: 7,
        status: PlaybackStatusMessage.error,
        error: PlaybackErrorMessage(
          code: 'network_failed',
          message: 'offline',
          isRecoverable: true,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final PlaybackStatusUpdate update = await platform
        .stateStream(7)
        .first
        .timeout(const Duration(seconds: 1));

    expect(update.state, VideoPlaybackState.error);
    expect(update.error?.code, 'network_failed');
  });

  test('position stream maps buffer and duration', () async {
    final Future<PlaybackPosition> next = platform.positionStream(7).first;

    positions.add(
      PositionEvent(
        controllerId: 7,
        positionMs: 1500,
        bufferedPositionMs: 5000,
        durationMs: 30000,
      ),
    );

    final PlaybackPosition position = await next;
    expect(position.position, const Duration(milliseconds: 1500));
    expect(position.bufferedPosition, const Duration(seconds: 5));
    expect(position.duration, const Duration(seconds: 30));
  });

  test('zero duration is reported as unknown', () async {
    final Future<PlaybackPosition> next = platform.positionStream(7).first;
    positions.add(PositionEvent(controllerId: 7, positionMs: 0, durationMs: 0));

    expect((await next).duration, isNull);
  });

  test(
    'position stream replays the latest position for a late subscriber',
    () async {
      await platform.initialize(const FeedPlayerConfig());
      positions.add(
        PositionEvent(
          controllerId: 7,
          positionMs: 4200,
          bufferedPositionMs: 9000,
          durationMs: 30000,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final PlaybackPosition position = await platform
          .positionStream(7)
          .first
          .timeout(const Duration(seconds: 1));

      expect(position.position, const Duration(milliseconds: 4200));
      expect(position.bufferedPosition, const Duration(milliseconds: 9000));
      expect(position.duration, const Duration(seconds: 30));
    },
  );

  test('setPlaybackSpeed rejects non-finite and non-positive speeds', () async {
    await platform.initialize(const FeedPlayerConfig());
    await platform.createController(
      sourceId: 'a',
      autoPlay: false,
      looping: false,
    );

    await expectLater(
      platform.setPlaybackSpeed(7, double.nan),
      throwsArgumentError,
    );
    await expectLater(
      platform.setPlaybackSpeed(7, double.infinity),
      throwsArgumentError,
    );
    await expectLater(platform.setPlaybackSpeed(7, 0.0), throwsArgumentError);
    await expectLater(platform.setPlaybackSpeed(7, -1.5), throwsArgumentError);
  });

  test('metrics stream maps the native payload', () async {
    final Future<VideoMetrics> next = platform.metricsStream(7).first;

    metrics.add(
      MetricsEvent(
        controllerId: 7,
        rebufferCount: 2,
        droppedFrames: 5,
        timestampMs: 1234,
        firstFrameLatencyMs: 140,
      ),
    );

    final VideoMetrics metric = await next;
    expect(metric.controllerId, 7);
    expect(metric.rebufferCount, 2);
    expect(metric.droppedFrames, 5);
    expect(metric.firstFrameLatency, const Duration(milliseconds: 140));
    expect(metric.timestamp, DateTime.fromMillisecondsSinceEpoch(1234));
  });

  test(
    'metrics stream replays the latest metric for a late subscriber',
    () async {
      await platform.initialize(const FeedPlayerConfig());
      metrics.add(
        MetricsEvent(
          controllerId: 7,
          rebufferCount: 0,
          droppedFrames: 0,
          timestampMs: 1234,
          firstFrameLatencyMs: 140,
        ),
      );

      final VideoMetrics metric = await platform.metricsStream(7).first;
      expect(metric.firstFrameLatency, const Duration(milliseconds: 140));
    },
  );

  test('video size stream is filtered per controller', () async {
    await platform.initialize(const FeedPlayerConfig());
    final Future<VideoSize> next = platform.videoSizeStream(7).first;

    videoSizes.add(
      VideoSizeEvent(
        controllerId: 99,
        width: 640,
        height: 360,
        rotationDegrees: 0,
      ),
    );
    videoSizes.add(
      VideoSizeEvent(
        controllerId: 7,
        width: 1920,
        height: 1080,
        rotationDegrees: 0,
      ),
    );

    expect(await next, const VideoSize(width: 1920, height: 1080));
  });

  test('late video size subscriber receives the latest value', () async {
    await platform.initialize(const FeedPlayerConfig());
    videoSizes.add(
      VideoSizeEvent(
        controllerId: 7,
        width: 1920,
        height: 1080,
        rotationDegrees: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final VideoSize size = await platform
        .videoSizeStream(7)
        .first
        .timeout(const Duration(seconds: 1));

    expect(size, const VideoSize(width: 1920, height: 1080));
  });

  test('lifecycle events become release events', () async {
    final Future<ControllerReleaseEvent> next = platform.releaseEvents.first;

    lifecycle.add(
      ControllerLifecycleEvent(
        controllerId: 7,
        reason: ReleaseReasonMessage.evicted,
      ),
    );

    final ControllerReleaseEvent event = await next;
    expect(event.controllerId, 7);
    expect(event.reason, ControllerReleaseReason.evicted);
  });

  test('cache queries are forwarded', () async {
    final CacheStatus status = await platform.cacheStatus('a');
    expect(status.cachedBytes, 512);
    expect(status.fraction, closeTo(0.25, 0.001));
    expect(await platform.cacheUsageBytes(), 4096);

    await platform.clearMediaCache();
    expect(hostApi.clearedCache, isTrue);

    await platform.evictCachedMedia(<String>['a']);
    expect(hostApi.evictRequest!.sourceIds, <String>['a']);
  });

  test(
    'empty source identifiers are rejected at the platform boundary',
    () async {
      expect(
        () => platform.createController(
          sourceId: ' ',
          autoPlay: false,
          looping: true,
        ),
        throwsArgumentError,
      );
      await expectLater(platform.setVisibleSource(''), throwsArgumentError);
      await expectLater(platform.cacheStatus(' '), throwsArgumentError);
      await expectLater(
        platform.evictCachedMedia(<String>['valid', '']),
        throwsArgumentError,
      );
      expect(hostApi.createRequest, isNull);
      expect(hostApi.visibleRequest, isNull);
    },
  );

  test('invalid volumes are rejected at the platform boundary', () async {
    await expectLater(platform.setVolume(7, double.nan), throwsArgumentError);
    await expectLater(
      platform.setVolume(7, double.infinity),
      throwsArgumentError,
    );
    await expectLater(platform.setVolume(7, -0.1), throwsArgumentError);
    await expectLater(platform.setVolume(7, 1.1), throwsArgumentError);
  });

  group('event stream errors', () {
    final List<FlutterErrorDetails> reported = <FlutterErrorDetails>[];
    void Function(FlutterErrorDetails)? previousHandler;

    setUp(() {
      previousHandler = FlutterError.onError;
      reported.clear();
      FlutterError.onError = (FlutterErrorDetails details) {
        reported.add(details);
      };
    });

    tearDown(() {
      FlutterError.onError = previousHandler;
    });

    test('cache subscription errors are reported, not unhandled', () async {
      await platform.initialize(const FeedPlayerConfig());
      final Object error = StateError('metrics channel failed');

      metrics.addError(error);
      await Future<void>.delayed(Duration.zero);

      expect(reported, hasLength(1));
      expect(reported.single.exception, same(error));
      expect(reported.single.library, 'native_feed_player');
    });

    test(
      'per-controller streams still propagate errors to listeners',
      () async {
        await platform.initialize(const FeedPlayerConfig());
        final Object error = StateError('state channel failed');
        final Completer<Object> received = Completer<Object>();

        final StreamSubscription<PlaybackStatusUpdate> subscription = platform
            .stateStream(7)
            .listen((_) {}, onError: received.complete);

        states.addError(error);
        expect(await received.future, same(error));
        await subscription.cancel();
      },
    );
  });
}
