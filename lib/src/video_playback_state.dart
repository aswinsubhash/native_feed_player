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
  disposed,
}

VideoPlaybackState playbackStateFromString(String value) {
  switch (value) {
    case 'idle':
      return VideoPlaybackState.idle;
    case 'preparing':
      return VideoPlaybackState.preparing;
    case 'ready':
      return VideoPlaybackState.ready;
    case 'playing':
      return VideoPlaybackState.playing;
    case 'paused':
      return VideoPlaybackState.paused;
    case 'buffering':
      return VideoPlaybackState.buffering;
    case 'completed':
      return VideoPlaybackState.completed;
    case 'disposed':
      return VideoPlaybackState.disposed;
    case 'error':
    default:
      return VideoPlaybackState.error;
  }
}
