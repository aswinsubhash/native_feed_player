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
* Added architecture and implementation backlog docs.
