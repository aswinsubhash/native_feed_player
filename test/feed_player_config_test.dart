import 'package:flutter_test/flutter_test.dart';
import 'package:native_feed_player/native_feed_player.dart';
import 'package:native_feed_player/src/messages.g.dart';

class _InvalidCachePolicy extends CachePolicy {
  const _InvalidCachePolicy() : super(maxBytes: 1);

  @override
  int get maxBytes => 0;
}

class _InvalidAudioPolicy extends AudioPolicy {
  const _InvalidAudioPolicy();

  @override
  double get volume => double.nan;
}

class _InvalidFeedPlayerConfig extends FeedPlayerConfig {
  const _InvalidFeedPlayerConfig();

  @override
  int get maxActivePlayers => 0;
}

void main() {
  group('FeedPlayerConfig', () {
    test('defaults suit a forward-travelling feed', () {
      const FeedPlayerConfig config = FeedPlayerConfig();

      expect(config.maxActivePlayers, 3);
      expect(
        config.preloadAhead,
        greaterThan(config.preloadBehind),
        reason: 'feeds travel forward, so the budget should too',
      );
      expect(config.renderMode, RenderMode.platformView);
      expect(config.positionUpdateInterval.inMilliseconds, 200);
    });

    test('audio defaults to audible with focus handling', () {
      const AudioPolicy audio = AudioPolicy();

      expect(audio.muted, isFalse);
      expect(audio.handleAudioFocus, isTrue);
    });

    test('cache defaults to an enabled 256 MB budget', () {
      const CachePolicy cache = CachePolicy();

      expect(cache.enabled, isTrue);
      expect(cache.maxBytes, 256 * 1024 * 1024);
    });

    test('invalid tuning is rejected at construction', () {
      expect(() => FeedPlayerConfig(maxActivePlayers: 0), throwsAssertionError);
      expect(() => FeedPlayerConfig(preloadAhead: -1), throwsAssertionError);
      expect(() => FeedPlayerConfig(preloadBehind: -1), throwsAssertionError);
      expect(
        () => FeedPlayerConfig(maxConcurrentPreloads: 0),
        throwsAssertionError,
      );
      expect(() => CachePolicy(maxBytes: 0), throwsAssertionError);
      expect(() => AudioPolicy(volume: 1.5), throwsAssertionError);
    });

    test('wire validation remains active independently of assertions', () {
      expect(const _InvalidCachePolicy().toMessage, throwsArgumentError);
      expect(const _InvalidAudioPolicy().toMessage, throwsArgumentError);
      expect(const _InvalidFeedPlayerConfig().toMessage, throwsArgumentError);

      final FeedPlayerConfig config = FeedPlayerConfig(
        positionUpdateInterval: Duration(microseconds: int.parse('1')),
      );
      expect(config.toMessage, throwsArgumentError);
    });

    test('copyWith changes one field and preserves the rest', () {
      const FeedPlayerConfig base = FeedPlayerConfig(
        maxActivePlayers: 5,
        preloadAhead: 4,
        cache: CachePolicy(maxBytes: 1024),
      );

      final FeedPlayerConfig updated = base.copyWith(
        audio: const AudioPolicy(muted: false),
      );

      expect(updated.audio.muted, isFalse);
      expect(updated.maxActivePlayers, 5);
      expect(updated.preloadAhead, 4);
      expect(updated.cache.maxBytes, 1024);
    });

    test('the whole config survives conversion to the wire format', () {
      const FeedPlayerConfig config = FeedPlayerConfig(
        maxActivePlayers: 4,
        preloadAhead: 3,
        preloadBehind: 2,
        maxConcurrentPreloads: 5,
        positionUpdateInterval: Duration(milliseconds: 333),
        renderMode: RenderMode.texture,
        cache: CachePolicy(enabled: false, maxBytes: 4096),
        audio: AudioPolicy(muted: false, volume: 0.25, handleAudioFocus: true),
      );

      final FeedPlayerConfigMessage message = config.toMessage();

      expect(message.maxActivePlayers, 4);
      expect(message.preloadAhead, 3);
      expect(message.preloadBehind, 2);
      expect(message.maxConcurrentPreloads, 5);
      expect(message.positionUpdateIntervalMs, 333);
      expect(message.renderMode, RenderModeMessage.texture);
      expect(message.cache.enabled, isFalse);
      expect(message.cache.maxBytes, 4096);
      expect(message.audio.muted, isFalse);
      expect(message.audio.volume, 0.25);
      expect(message.audio.handleAudioFocus, isTrue);
    });
  });

  group('FeedSource', () {
    test('ranks are assigned by caller order, not identity', () {
      const FeedSource source = FeedSource(id: 'a', uri: 'a.mp4');

      expect(source.toMessage(7).rank, 7);
      expect(source.toMessage(0).id, 'a');
    });

    test('media kind and headers reach the wire format', () {
      const FeedSource source = FeedSource(
        id: 'a',
        uri: 'a.m3u8',
        kind: FeedMediaKind.hls,
        headers: <String, String>{'Authorization': 'Bearer t'},
      );

      final FeedSourceMessage message = source.toMessage(0);

      expect(message.kind, FeedMediaKindMessage.hls);
      expect(message.headers['Authorization'], 'Bearer t');
    });

    test('headers participate in equality and hashing', () {
      const FeedSource first = FeedSource(
        id: 'a',
        uri: 'a.mp4',
        headers: <String, String>{'a': '1', 'b': '2'},
      );
      const FeedSource reordered = FeedSource(
        id: 'a',
        uri: 'a.mp4',
        headers: <String, String>{'b': '2', 'a': '1'},
      );
      const FeedSource different = FeedSource(
        id: 'a',
        uri: 'a.mp4',
        headers: <String, String>{'a': 'changed', 'b': '2'},
      );

      expect(first, reordered);
      expect(first.hashCode, reordered.hashCode);
      expect(first, isNot(different));
    });

    test('toString redacts URI query values', () {
      const FeedSource source = FeedSource(
        id: 'a',
        uri: 'https://example.test/video.mp4?token=secret&signature=value#part',
      );

      final String description = source.toString();

      expect(description, contains('https://example.test/video.mp4'));
      expect(description, contains('#part'));
      expect(description, isNot(contains('secret')));
      expect(description, isNot(contains('signature')));
    });

    test('wire conversion rejects empty ids and uris', () {
      expect(
        () => const FeedSource(id: ' ', uri: 'a.mp4').toMessage(0),
        throwsArgumentError,
      );
      expect(
        () => const FeedSource(id: 'a', uri: ' ').toMessage(0),
        throwsArgumentError,
      );
    });
  });

  group('VideoSize', () {
    test('aspect ratio uses the unrotated dimensions', () {
      const VideoSize portrait = VideoSize(width: 1080, height: 1920);
      expect(portrait.aspectRatio, closeTo(1080 / 1920, 0.0001));
    });

    test('a quarter turn swaps the ratio', () {
      const VideoSize rotated = VideoSize(
        width: 1920,
        height: 1080,
        rotationDegrees: 90,
      );
      expect(rotated.aspectRatio, closeTo(1080 / 1920, 0.0001));
    });

    test('an unknown size reports a safe ratio', () {
      expect(VideoSize.zero.isKnown, isFalse);
      expect(VideoSize.zero.aspectRatio, 1);
    });
  });

  group('CacheStatus', () {
    test('fraction is clamped and safe when the total is unknown', () {
      const CacheStatus unknown = CacheStatus(
        sourceId: 'a',
        cachedBytes: 100,
        totalBytes: 0,
        isComplete: false,
      );
      expect(unknown.fraction, 0);

      const CacheStatus partial = CacheStatus(
        sourceId: 'a',
        cachedBytes: 512,
        totalBytes: 2048,
        isComplete: false,
      );
      expect(partial.fraction, closeTo(0.25, 0.0001));
    });
  });
}
