import 'package:flutter/foundation.dart';

import '../native_reels_player_platform_interface.dart';
import 'video_metrics.dart';
import 'video_playback_state.dart';

/// Handle for controlling a single native video instance.
class VideoController {
  VideoController({
    required this.controllerId,
    required this.url,
    required this.index,
    required NativeReelsPlayerPlatform platform,
  }) : _platform = platform;

  final int controllerId;
  final String url;
  final int index;

  final NativeReelsPlayerPlatform _platform;

  Stream<Duration> get positionStream => _platform.positionStream(controllerId);

  Stream<VideoPlaybackState> get stateStream =>
      _platform.stateStream(controllerId);

  Stream<VideoMetrics> get metricsStream =>
      _platform.metricsStream(controllerId);

  Future<void> play() => _platform.play(controllerId);

  Future<void> pause() => _platform.pause(controllerId);

  Future<void> seekTo(Duration position) =>
      _platform.seekTo(controllerId, position);

  Future<void> dispose() => _platform.disposeController(controllerId);

  @override
  String toString() {
    return 'VideoController(id: $controllerId, index: $index, url: $url)';
  }

  @visibleForTesting
  NativeReelsPlayerPlatform get platform => _platform;
}
