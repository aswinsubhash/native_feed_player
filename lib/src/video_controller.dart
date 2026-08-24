import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native_feed_player_platform_interface.dart';
import 'controller_release.dart';
import 'feed_player_exception.dart';
import 'video_metrics.dart';
import 'video_playback_state.dart';

/// Handle for controlling the native player bound to one [FeedSource].
///
/// A controller stays usable only while its native player is alive. The native
/// scheduler may reclaim a player at any time (window eviction, memory
/// pressure), so commands issued afterwards throw [ControllerReleasedError]
/// instead of silently doing nothing.
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

  /// Whether the native player backing this controller is gone.
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

  /// Releases the native player. Safe to call more than once.
  Future<void> dispose() async {
    if (isReleased) {
      return;
    }
    markReleased(ControllerReleaseReason.disposed);
    await _platform.disposeController(controllerId);
  }

  /// Marks this controller dead without issuing a native dispose call.
  ///
  /// Called by the owning player when native code reports that it reclaimed
  /// the player on its own.
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

  /// Platform implementation backing this controller.
  ///
  /// Exposed so widgets in this package bind to the same (possibly injected)
  /// platform as the controller rather than the global singleton.
  @internal
  FeedPlayerPlatform get platform => _platform;

  @override
  String toString() =>
      'FeedController(id: $controllerId, source: $sourceId, '
      'released: $isReleased)';
}

/// Former name of [FeedController].
@Deprecated('Renamed to FeedController. Will be removed in 0.2.0.')
typedef VideoController = FeedController;
