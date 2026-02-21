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
* Implemented milestone 6 production hardening:
  * Added `metricsStream` to `VideoController`
  * Added native metrics channel (`native_reels_player/metrics`) on Android/iOS
  * Added first-frame latency, rebuffer count, and dropped-frame estimate payloads
  * Added integration test scenarios for:
    * fast fling index churn
    * pause/resume lifecycle path
    * network loss/recovery path
  * Added release checklist and README tuning/limitations guidance
* Completed pending Milestone 1 contract migration:
  * Added Pigeon schema and generated Dart/Kotlin/Swift bindings
  * Migrated command RPC from raw `MethodChannel.invokeMethod` strings to typed Pigeon host API calls
* Completed pending Milestone 4 render-target recycling:
  * Added Android `TextureViewPool` for platform-view reuse
  * Added iOS `RenderViewPool` for `AVPlayerLayer` view reuse
  * Updated platform view factories to acquire/release pooled render views
* Added architecture and implementation backlog docs.
