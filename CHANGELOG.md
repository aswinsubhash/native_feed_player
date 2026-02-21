## 0.0.1

* Scaffolded Flutter plugin for iOS and Android.
* Added reels-oriented Dart API:
  * `NativeReelsPlayer.initialize`
  * `NativeReelsPlayer.preload`
  * `NativeReelsPlayer.getController`
  * controller playback/lifecycle commands
* Implemented native single-controller playback:
  * iOS: `AVPlayer`
  * Android: Media3 `ExoPlayer`
* Added native event channels for playback state and position updates.
* Added milestone 3 pre-buffering primitives:
  * index-window preload around visible item
  * tuned Android `LoadControl` prewarm prepare
  * stale preload cancellation using generation checks
* Added architecture and implementation backlog docs.
