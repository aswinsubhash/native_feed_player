import 'messages.g.dart';
import 'playback_error.dart';

/// Playback states emitted by the native player.
enum VideoPlaybackState {
  idle,
  preparing,
  ready,
  playing,
  paused,
  buffering,
  completed,
  error,

  /// The native player no longer exists. Terminal.
  released,
}

/// A playback state update, with failure detail when [state] is
/// [VideoPlaybackState.error].
class PlaybackStatusUpdate {
  const PlaybackStatusUpdate({required this.state, this.error});

  final VideoPlaybackState state;
  final PlaybackError? error;

  bool get isTerminal =>
      state == VideoPlaybackState.released || state == VideoPlaybackState.error;

  @override
  String toString() =>
      'PlaybackStatusUpdate(${state.name}${error == null ? '' : ', $error'})';
}

VideoPlaybackState playbackStateFromMessage(PlaybackStatusMessage message) {
  switch (message) {
    case PlaybackStatusMessage.idle:
      return VideoPlaybackState.idle;
    case PlaybackStatusMessage.preparing:
      return VideoPlaybackState.preparing;
    case PlaybackStatusMessage.ready:
      return VideoPlaybackState.ready;
    case PlaybackStatusMessage.playing:
      return VideoPlaybackState.playing;
    case PlaybackStatusMessage.paused:
      return VideoPlaybackState.paused;
    case PlaybackStatusMessage.buffering:
      return VideoPlaybackState.buffering;
    case PlaybackStatusMessage.completed:
      return VideoPlaybackState.completed;
    case PlaybackStatusMessage.error:
      return VideoPlaybackState.error;
    case PlaybackStatusMessage.released:
      return VideoPlaybackState.released;
  }
}
