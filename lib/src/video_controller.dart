import 'dart:async';

import 'package:flutter/foundation.dart';

// Constructor parameter names are part of the public API.
// ignore_for_file: prefer_initializing_formals

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
       _onReleasedCallback = onReleasedCallback {
    if (sourceId.trim().isEmpty) {
      throw ArgumentError.value(sourceId, 'sourceId', 'Must not be empty.');
    }
    _observeFirstFrame();
  }

  final int controllerId;

  /// Identifier of the [FeedSource] this controller plays.
  final String sourceId;

  final FeedPlayerPlatform _platform;
  final void Function(FeedController controller)? _onReleasedCallback;
  final Completer<ControllerReleaseReason> _released =
      Completer<ControllerReleaseReason>();
  final Completer<Duration> _firstFrame = Completer<Duration>();

  StreamSubscription<VideoMetrics>? _firstFrameSubscription;
  Future<void>? _disposeOperation;
  late final Future<Duration> _firstFrameRendered;
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
    if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Must be finite and within 0..1.',
      );
    }
    return _platform.setVolume(controllerId, volume);
  }

  Future<void> setMuted(bool muted) {
    _ensureAlive();
    return _platform.setMuted(controllerId, muted);
  }

  /// Playback rate, clamped natively to 0.25..4.
  Future<void> setPlaybackSpeed(double speed) {
    _ensureAlive();
    if (!speed.isFinite || speed <= 0.0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and positive.');
    }
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
  Future<Duration> get firstFrameRendered => _firstFrameRendered;

  /// Releases the native player. Safe to call more than once.
  Future<void> dispose() {
    if (isReleased) {
      return Future<void>.value();
    }
    final Future<void>? operation = _disposeOperation;
    if (operation != null) {
      return operation;
    }
    return _disposeOperation = _disposeNative();
  }

  Future<void> _disposeNative() async {
    try {
      await _platform.disposeController(controllerId);
      markReleased(ControllerReleaseReason.disposed);
    } finally {
      if (!isReleased) {
        _disposeOperation = null;
      }
    }
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
    if (!_firstFrame.isCompleted) {
      _firstFrame.completeError(
        ControllerReleasedError(controllerId: controllerId, reason: reason),
      );
    }
    _cancelFirstFrameSubscription();
    _onReleasedCallback?.call(this);
  }

  void _observeFirstFrame() {
    _firstFrameRendered = _firstFrame.future;
    _firstFrameRendered.then<void>((_) {}, onError: (_) {});
    try {
      final StreamSubscription<VideoMetrics> subscription = metricsStream
          .listen(
            (VideoMetrics metrics) {
              final Duration? latency = metrics.firstFrameLatency;
              if (latency == null || _firstFrame.isCompleted) {
                return;
              }
              _firstFrame.complete(latency);
              _cancelFirstFrameSubscription();
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!_firstFrame.isCompleted) {
                _firstFrame.completeError(error, stackTrace);
              }
              _cancelFirstFrameSubscription();
            },
            onDone: () {
              if (!_firstFrame.isCompleted) {
                _firstFrame.completeError(
                  StateError('Metrics stream ended before the first frame.'),
                );
              }
              _firstFrameSubscription = null;
            },
          );
      _firstFrameSubscription = subscription;
      if (_firstFrame.isCompleted) {
        _cancelFirstFrameSubscription();
      }
    } catch (error, stackTrace) {
      _firstFrame.completeError(error, stackTrace);
    }
  }

  void _cancelFirstFrameSubscription() {
    final StreamSubscription<VideoMetrics>? subscription =
        _firstFrameSubscription;
    _firstFrameSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
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
