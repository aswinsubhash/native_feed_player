import 'messages.g.dart';

/// Persistent media cache settings.
class CachePolicy {
  const CachePolicy({this.enabled = true, this.maxBytes = defaultMaxBytes})
    : assert(maxBytes > 0, 'maxBytes must be positive');

  /// Conservative default that stays safe on low-storage devices.
  static const int defaultMaxBytes = 256 * 1024 * 1024;

  /// Disables caching entirely. Playback still buffers in memory.
  static const CachePolicy disabled = CachePolicy(enabled: false);

  final bool enabled;

  /// Upper bound on bytes retained on disk, enforced with LRU eviction.
  final int maxBytes;

  CachePolicyMessage toMessage() =>
      CachePolicyMessage(enabled: enabled, maxBytes: maxBytes);
}

/// Audio behaviour for the feed.
class AudioPolicy {
  const AudioPolicy({
    this.muted = true,
    this.volume = 1.0,
    this.handleAudioFocus = false,
  }) : assert(volume >= 0.0 && volume <= 1.0, 'volume must be within 0..1');

  /// Feeds conventionally start muted and unmute on explicit user intent, so
  /// that is the default here too.
  final bool muted;
  final double volume;

  /// Whether playback should request audio focus and duck/pause other apps.
  /// Leave false while muted.
  final bool handleAudioFocus;

  AudioPolicy copyWith({bool? muted, double? volume, bool? handleAudioFocus}) {
    return AudioPolicy(
      muted: muted ?? this.muted,
      volume: volume ?? this.volume,
      handleAudioFocus: handleAudioFocus ?? this.handleAudioFocus,
    );
  }

  AudioPolicyMessage toMessage() => AudioPolicyMessage(
    muted: muted,
    volume: volume,
    handleAudioFocus: handleAudioFocus,
  );
}

/// How native video output reaches the Flutter scene.
///
/// Both paths are supported so the choice can be measured per device class
/// rather than assumed; see `doc/RENDERING_BENCHMARK.md`.
enum RenderMode {
  /// A native view composited by Flutter's platform-view layer. Most
  /// compatible, but compositing costs a synchronisation step per frame.
  platformView,

  /// Frames copied into a Flutter texture and drawn by the Flutter renderer.
  /// Usually smoother while scrolling.
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

  /// Controllers kept alive at once. Everything beyond this is evicted by
  /// distance from the visible source.
  final int maxActivePlayers;

  /// How many sources past the visible one to prepare. Feeds travel forward,
  /// so this is normally larger than [preloadBehind].
  final int preloadAhead;

  /// How many sources before the visible one to keep prepared, for backwards
  /// scrolling.
  final int preloadBehind;

  /// Ceiling on simultaneous preload work, so a fling cannot saturate the
  /// network with requests that are about to become stale.
  final int maxConcurrentPreloads;

  final Duration positionUpdateInterval;
  final RenderMode renderMode;
  final CachePolicy cache;
  final AudioPolicy audio;

  FeedPlayerConfigMessage toMessage() => FeedPlayerConfigMessage(
    maxActivePlayers: maxActivePlayers,
    preloadAhead: preloadAhead,
    preloadBehind: preloadBehind,
    maxConcurrentPreloads: maxConcurrentPreloads,
    positionUpdateIntervalMs: positionUpdateInterval.inMilliseconds,
    renderMode: renderMode.toMessage(),
    cache: cache.toMessage(),
    audio: audio.toMessage(),
  );

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
