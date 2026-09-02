import 'messages.g.dart';

/// Persistent media cache settings.
class CachePolicy {
  const CachePolicy({this.enabled = true, this.maxBytes = defaultMaxBytes})
    : assert(maxBytes > 0, 'maxBytes must be positive');

  /// Default 256 MB cache limit.
  static const int defaultMaxBytes = 256 * 1024 * 1024;

  /// Disables caching entirely. Playback still buffers in memory.
  static const CachePolicy disabled = CachePolicy(enabled: false);

  final bool enabled;

  /// Upper bound on bytes retained on disk, enforced with LRU eviction.
  final int maxBytes;

  CachePolicyMessage toMessage() {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'Must be positive.');
    }
    return CachePolicyMessage(enabled: enabled, maxBytes: maxBytes);
  }
}

/// Audio behaviour for the feed.
class AudioPolicy {
  const AudioPolicy({
    this.muted = false,
    this.volume = 1.0,
    this.handleAudioFocus = true,
    this.manageAudioSession = true,
  }) : assert(volume >= 0.0 && volume <= 1.0, 'volume must be within 0..1');

  /// Whether playback starts without audible output.
  final bool muted;
  final double volume;

  /// Whether audible playback requests platform audio focus.
  final bool handleAudioFocus;

  /// iOS only. When false the plugin never reconfigures `AVAudioSession`; the
  /// host app owns category, mode, and activation. Android audio focus is
  /// still controlled by [handleAudioFocus].
  final bool manageAudioSession;

  AudioPolicy copyWith({
    bool? muted,
    double? volume,
    bool? handleAudioFocus,
    bool? manageAudioSession,
  }) {
    return AudioPolicy(
      muted: muted ?? this.muted,
      volume: volume ?? this.volume,
      handleAudioFocus: handleAudioFocus ?? this.handleAudioFocus,
      manageAudioSession: manageAudioSession ?? this.manageAudioSession,
    );
  }

  AudioPolicyMessage toMessage() {
    if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Must be finite and within 0..1.',
      );
    }
    return AudioPolicyMessage(
      muted: muted,
      volume: volume,
      handleAudioFocus: handleAudioFocus,
      manageAudioSession: manageAudioSession,
    );
  }
}

/// Native video output mode.
///
/// See `doc/RENDERING_BENCHMARK.md` for performance guidance.
enum RenderMode {
  /// Native compositing through a Flutter platform view.
  platformView,

  /// Flutter texture rendering.
  texture,
}

extension RenderModeMessaging on RenderMode {
  RenderModeMessage toMessage() {
    switch (this) {
      case RenderMode.platformView:
        return RenderModeMessage.platformView;
      case RenderMode.texture:
        return RenderModeMessage.texture;
    }
  }
}

/// Tuning for the native scheduler.
class FeedPlayerConfig {
  const FeedPlayerConfig({
    this.maxActivePlayers = 3,
    this.preloadAhead = 2,
    this.preloadBehind = 1,
    this.maxConcurrentPreloads = 2,
    this.positionUpdateInterval = const Duration(milliseconds: 200),
    this.renderMode = RenderMode.platformView,
    this.cache = const CachePolicy(),
    this.audio = const AudioPolicy(),
  }) : assert(maxActivePlayers >= 1, 'maxActivePlayers must be at least 1'),
       assert(preloadAhead >= 0, 'preloadAhead cannot be negative'),
       assert(preloadBehind >= 0, 'preloadBehind cannot be negative'),
       assert(
         maxConcurrentPreloads >= 1,
         'maxConcurrentPreloads must be at least 1',
       );

  /// Maximum active controllers. Distant controllers are evicted.
  final int maxActivePlayers;

  /// Sources to preload ahead of the visible source.
  final int preloadAhead;

  /// Sources to preload behind the visible source.
  final int preloadBehind;

  /// Maximum concurrent preload operations.
  final int maxConcurrentPreloads;

  final Duration positionUpdateInterval;
  final RenderMode renderMode;
  final CachePolicy cache;
  final AudioPolicy audio;

  FeedPlayerConfigMessage toMessage() {
    if (maxActivePlayers < 1) {
      throw ArgumentError.value(
        maxActivePlayers,
        'maxActivePlayers',
        'Must be at least 1.',
      );
    }
    if (preloadAhead < 0) {
      throw ArgumentError.value(
        preloadAhead,
        'preloadAhead',
        'Cannot be negative.',
      );
    }
    if (preloadBehind < 0) {
      throw ArgumentError.value(
        preloadBehind,
        'preloadBehind',
        'Cannot be negative.',
      );
    }
    if (maxConcurrentPreloads < 1) {
      throw ArgumentError.value(
        maxConcurrentPreloads,
        'maxConcurrentPreloads',
        'Must be at least 1.',
      );
    }
    if (positionUpdateInterval.inMilliseconds <= 0) {
      throw ArgumentError.value(
        positionUpdateInterval,
        'positionUpdateInterval',
        'Must be at least 1 millisecond.',
      );
    }
    return FeedPlayerConfigMessage(
      maxActivePlayers: maxActivePlayers,
      preloadAhead: preloadAhead,
      preloadBehind: preloadBehind,
      maxConcurrentPreloads: maxConcurrentPreloads,
      positionUpdateIntervalMs: positionUpdateInterval.inMilliseconds,
      renderMode: renderMode.toMessage(),
      cache: cache.toMessage(),
      audio: audio.toMessage(),
    );
  }

  FeedPlayerConfig copyWith({
    int? maxActivePlayers,
    int? preloadAhead,
    int? preloadBehind,
    int? maxConcurrentPreloads,
    Duration? positionUpdateInterval,
    RenderMode? renderMode,
    CachePolicy? cache,
    AudioPolicy? audio,
  }) {
    return FeedPlayerConfig(
      maxActivePlayers: maxActivePlayers ?? this.maxActivePlayers,
      preloadAhead: preloadAhead ?? this.preloadAhead,
      preloadBehind: preloadBehind ?? this.preloadBehind,
      maxConcurrentPreloads:
          maxConcurrentPreloads ?? this.maxConcurrentPreloads,
      positionUpdateInterval:
          positionUpdateInterval ?? this.positionUpdateInterval,
      renderMode: renderMode ?? this.renderMode,
      cache: cache ?? this.cache,
      audio: audio ?? this.audio,
    );
  }
}
