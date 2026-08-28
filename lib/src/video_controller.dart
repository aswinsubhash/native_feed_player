import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native_feed_player_platform_interface.dart';
import 'controller_release.dart';
import 'feed_player_exception.dart';
import 'video_metrics.dart';
import 'video_playback_state.dart';
import 'video_size.dart';

/// A handle to the native player for one [FeedSource].
///
/// The native scheduler may release the player at any time. Commands issued
/// after release throw [ControllerReleasedError].
class FeedController {
  FeedController({
    required this.controllerId,
    required this.sourceId,
    required FeedPlayerPlatform platform,
    void Function(FeedController controller)? onReleasedCallback,
  }) : _platform = platform,
       _onReleasedCallback = onReleasedCallback;

  final int controllerId;

  /// Identifier of the [FeedSource] this controller plays.
  final String sourceId;

  final FeedPlayerPlatform _platform;
  final void Function(FeedController controller)? _onReleasedCallback;
  final Completer<ControllerReleaseReason> _released =
      Completer<ControllerReleaseReason>();

  ControllerReleaseReason? _releaseReason;

  /// Whether the native player has been released.
  bool get isReleased => _releaseReason != null;

  /// Why the controller was released, or `null` while it is still alive.
  ControllerReleaseReason? get releaseReason => _releaseReason;

  /// Completes when the native player is released, for any reason.
  Future<ControllerReleaseReason> get onReleased => _released.future;

  Stream<PlaybackPosition> get positionStream =>
      _platform.positionStream(controllerId);

  Stream<PlaybackStatusUpdate> get stateStream =>
      _platform.stateStream(controllerId);

  Stream<VideoMetrics> get metricsStream =>
      _platform.metricsStream(controllerId);

  Future<void> play() {
    _ensureAlive();
    return _platform.play(controllerId);
  }

  Future<void> pause() {
    _ensureAlive();
    return _platform.pause(controllerId);
  }

  Future<void> seekTo(Duration position) {
    _ensureAlive();
    return _platform.seekTo(controllerId, position);
  }

  /// Sets output level in the range 0..1. Ignored while muted.
  Future<void> setVolume(double volume) {
    _ensureAlive();
    return _platform.setVolume(controllerId, volume.clamp(0.0, 1.0));
  }

  Future<void> setMuted(bool muted) {
    _ensureAlive();
    return _platform.setMuted(controllerId, muted);
  }

  /// Playback rate, clamped natively to 0.25..4.
  Future<void> setPlaybackSpeed(double speed) {
    _ensureAlive();
    return _platform.setPlaybackSpeed(controllerId, speed);
  }

  Future<void> setLooping(bool looping) {
    _ensureAlive();
    return _platform.setLooping(controllerId, looping);
  }

  /// Emits the latest decoded dimensions on listen, then any later changes.
  Stream<VideoSize> get videoSizeStream =>
      _platform.videoSizeStream(controllerId);

  /// Completes when the first frame is rendered.
  Future<Duration> get firstFrameRendered {
    return metricsStream
        .map((VideoMetrics metrics) => metrics.firstFrameLatency)
        .where((Duration? latency) => latency != null)
        .cast<Duration>()
        .first;
  }

  /// Releases the native player. Safe to call more than once.
  Future<void> dispose() async {
    if (isReleased) {
      return;
    }
    markReleased(ControllerReleaseReason.disposed);
    await _platform.disposeController(controllerId);
  }

  /// Marks a controller released by the native scheduler.
  @internal
  void markReleased(ControllerReleaseReason reason) {
    if (isReleased) {
      return;
    }
    _releaseReason = reason;
    if (!_released.isCompleted) {
      _released.complete(reason);
    }
    _onReleasedCallback?.call(this);
  }

  void _ensureAlive() {
    final ControllerReleaseReason? reason = _releaseReason;
    if (reason != null) {
      throw ControllerReleasedError(controllerId: controllerId, reason: reason);
    }
  }

  /// Platform implementation used by this controller and package widgets.
  @internal
  FeedPlayerPlatform get platform => _platform;

  @override
  String toString() =>
      'FeedController(id: $controllerId, source: $sourceId, '
      'released: $isReleased)';
}
