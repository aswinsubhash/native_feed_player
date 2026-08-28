import 'dart:async';

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
        maxConcurrentPreloads: 2,
        cache: CachePolicy(maxBytes: 1024),
        audio: AudioPolicy(muted: false, volume: 0.5),
      ),
    );

    final FeedPlayerConfigMessage config = hostApi.initializeRequest!;
    expect(config.maxActivePlayers, 4);
    expect(config.preloadAhead, 3);
    expect(config.preloadBehind, 1);
    expect(config.cache.maxBytes, 1024);
    expect(config.audio.muted, isFalse);
    expect(config.audio.volume, 0.5);
  });

  test('setSources assigns sequential ranks', () async {
    await platform.setSources(<FeedSource>[
      const FeedSource(id: 'a', uri: 'a.mp4'),
      const FeedSource(id: 'b', uri: 'b.mp4'),
    ]);

    expect(
      hostApi.setSourcesRequest!.map((FeedSourceMessage m) => (m.id, m.rank)),
      <(String, int)>[('a', 0), ('b', 1)],
    );
  });

  test('appendSources continues ranks from the offset', () async {
    await platform.appendSources(<FeedSource>[
      const FeedSource(id: 'c', uri: 'c.mp4'),
      const FeedSource(id: 'd', uri: 'd.mp4'),
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
        uri: 'a.m3u8',
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
}
