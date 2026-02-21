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
* Started milestone 4 memory/pooling support:
  * index-aware player pooling and eviction by visible window
  * low-memory callbacks on Android and iOS
* Implemented milestone 5 platform-view rendering:
  * Android `TextureView` platform view factory
  * iOS `UIView`/`AVPlayerLayer` platform view factory
  * Dart `NativeVideoView` widget with attach/detach lifecycle wiring
* Added architecture and implementation backlog docs.
