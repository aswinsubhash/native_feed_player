import 'package:pigeon/pigeon.dart';

/// How a source should be treated by the native loader.
enum FeedMediaKindMessage { auto, progressive, hls }

/// Native playback status for a single controller.
enum PlaybackStatusMessage {
  idle,
  preparing,
  ready,
  playing,
  paused,
  buffering,
  completed,
  error,
  released,
}

/// Why a controller stopped existing.
enum ReleaseReasonMessage { disposed, evicted, error, engineDetached }

/// How native video output reaches the Flutter scene.
enum RenderModeMessage {
  /// A native view composited by Flutter's platform-view layer.
  platformView,

  /// Frames copied into a Flutter texture, drawn by the Flutter renderer.
  texture,
}

class FeedSourceMessage {
  FeedSourceMessage({
    required this.id,
    required this.uri,
    required this.rank,
    required this.kind,
    required this.headers,
    this.cacheKey,
  });

  /// Caller-owned stable identifier. Survives pagination and reordering.
  final String id;
  final String uri;

  /// Position in the feed, used only to rank preload priority.
  final int rank;
  final FeedMediaKindMessage kind;
  final Map<String, String> headers;

  /// Optional stable cache identity. When set, it replaces the URI in the
  /// cache key so signed or expiring URLs still share one cache entry.
  final String? cacheKey;
}

class CachePolicyMessage {
  CachePolicyMessage({required this.enabled, required this.maxBytes});

  final bool enabled;
  final int maxBytes;
}

class AudioPolicyMessage {
  AudioPolicyMessage({
    required this.muted,
    required this.volume,
    required this.handleAudioFocus,
    required this.manageAudioSession,
  });

  final bool muted;
  final double volume;

  /// Whether audible playback requests platform audio focus.
  final bool handleAudioFocus;

  /// iOS only. When false the plugin never reconfigures AVAudioSession; the
  /// host app owns category, mode, and activation.
  final bool manageAudioSession;
}

class FeedPlayerConfigMessage {
  FeedPlayerConfigMessage({
    required this.maxActivePlayers,
    required this.preloadAhead,
    required this.preloadBehind,
    required this.maxConcurrentPreloads,
    required this.positionUpdateIntervalMs,
    required this.renderMode,
    required this.cache,
    required this.audio,
  });

  final int maxActivePlayers;
  final int preloadAhead;
  final int preloadBehind;
  final int maxConcurrentPreloads;
  final int positionUpdateIntervalMs;
  final RenderModeMessage renderMode;
  final CachePolicyMessage cache;
  final AudioPolicyMessage audio;
}

class CreateControllerRequest {
  CreateControllerRequest({
    required this.sourceId,
    required this.autoPlay,
    required this.looping,
  });

  final String sourceId;
  final bool autoPlay;
  final bool looping;
}

class ControllerRequest {
  ControllerRequest({required this.controllerId});

  final int controllerId;
}

class SeekRequest {
  SeekRequest({required this.controllerId, required this.positionMs});

  final int controllerId;
  final int positionMs;
}

class VisibleSourceRequest {
  VisibleSourceRequest({required this.sourceId});

  final String sourceId;
}

class ControllerDoubleRequest {
  ControllerDoubleRequest({required this.controllerId, required this.value});

  final int controllerId;
  final double value;
}

class ControllerFlagRequest {
  ControllerFlagRequest({required this.controllerId, required this.value});

  final int controllerId;
  final bool value;
}

class AttachViewRequest {
  AttachViewRequest({required this.controllerId, required this.viewId});

  final int controllerId;
  final int viewId;
}

class SourceIdsRequest {
  SourceIdsRequest({required this.sourceIds});

  final List<String> sourceIds;
}

class CacheStatusMessage {
  CacheStatusMessage({
    required this.sourceId,
    required this.cachedBytes,
    required this.totalBytes,
    required this.isComplete,
  });

  final String sourceId;
  final int cachedBytes;
  final int totalBytes;
  final bool isComplete;
}

class PlaybackErrorMessage {
  PlaybackErrorMessage({
    required this.code,
    required this.message,
    required this.isRecoverable,
    this.platformCode,
  });

  final String code;
  final String message;
  final bool isRecoverable;
  final String? platformCode;
}

class PlaybackStateEvent {
  PlaybackStateEvent({
    required this.controllerId,
    required this.status,
    this.error,
  });

  final int controllerId;
  final PlaybackStatusMessage status;
  final PlaybackErrorMessage? error;
}

class PositionEvent {
  PositionEvent({
    required this.controllerId,
    required this.positionMs,
    this.bufferedPositionMs,
    this.durationMs,
  });

  final int controllerId;
  final int positionMs;
  final int? bufferedPositionMs;
  final int? durationMs;
}

class MetricsEvent {
  MetricsEvent({
    required this.controllerId,
    required this.rebufferCount,
    required this.droppedFrames,
    required this.timestampMs,
    this.firstFrameLatencyMs,
  });

  final int controllerId;
  final int rebufferCount;

  /// Monotonic total for the controller's lifetime on both platforms.
  final int droppedFrames;
  final int timestampMs;

  /// Milliseconds from controller creation to the first rendered video frame.
  final int? firstFrameLatencyMs;
}

class VideoSizeEvent {
  VideoSizeEvent({
    required this.controllerId,
    required this.width,
    required this.height,
    required this.rotationDegrees,
  });

  final int controllerId;

  /// Decoded pixel dimensions, before [rotationDegrees] is applied.
  final int width;
  final int height;

  /// Clockwise rotation the renderer must apply, in degrees.
  final int rotationDegrees;
}

class ControllerLifecycleEvent {
  ControllerLifecycleEvent({required this.controllerId, required this.reason});

  final int controllerId;
  final ReleaseReasonMessage reason;
}

@HostApi()
abstract class NativeFeedPlayerHostApi {
  void initialize(FeedPlayerConfigMessage config);

  /// Replaces the whole feed.
  void setSources(List<FeedSourceMessage> sources);

  /// Appends a page without renumbering existing sources.
  void appendSources(List<FeedSourceMessage> sources);

  void removeSources(SourceIdsRequest request);

  int createController(CreateControllerRequest request);

  void disposeController(ControllerRequest request);

  void play(ControllerRequest request);

  void pause(ControllerRequest request);

  void seekTo(SeekRequest request);

  void setVolume(ControllerDoubleRequest request);

  void setMuted(ControllerFlagRequest request);

  void setPlaybackSpeed(ControllerDoubleRequest request);

  void setLooping(ControllerFlagRequest request);

  /// Applies to every controller, current and future.
  void setAudioPolicy(AudioPolicyMessage policy);

  void setVisibleSource(VisibleSourceRequest request);

  /// Drops persisted media bytes for the given sources, or all of them when
  /// the list is empty.
  @async
  void evictCachedMedia(SourceIdsRequest request);

  @async
  void clearMediaCache();

  @async
  CacheStatusMessage cacheStatus(VisibleSourceRequest request);

  @async
  int cacheUsageBytes();

  void attachView(AttachViewRequest request);

  void detachView(ControllerRequest request);

  /// Binds the controller to a Flutter texture and returns its id.
  int attachTexture(ControllerRequest request);

  void detachTexture(ControllerRequest request);

  void disposeAll();
}

@EventChannelApi()
abstract class NativeFeedPlayerEventApi {
  PlaybackStateEvent playbackStateEvents();

  PositionEvent positionEvents();

  MetricsEvent metricsEvents();

  VideoSizeEvent videoSizeEvents();

  ControllerLifecycleEvent lifecycleEvents();
}
