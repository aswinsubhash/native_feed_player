## 0.1.0

Renamed from `native_reels_player`. The API is redesigned and not
source-compatible with 0.0.1; old names remain as deprecated typedefs for one
release.

**Breaking**

* Sources are registered up front as `FeedSource` values with caller-owned
  stable ids: `setSources`, `appendSources`, `removeSources`,
  `setVisibleSource`, `controllerFor`. Appending a page no longer renumbers or
  invalidates the feed.
* `NativeFeedPlayer` is now `FeedPlayer`, `VideoController` is now
  `FeedController`.
* Tuning moved into `FeedPlayerConfig` (window sizes, preload concurrency,
  position cadence, render mode, cache policy, audio policy).
* `clearCache()` is replaced by `clearMediaCache`, `evictCachedMedia`,
  `cacheStatus`, and `cacheUsageBytes`. It previously named a cache that did not
  exist.
* Playback state is delivered as `PlaybackStatusUpdate`, carrying a structured
  `PlaybackError` with a code, message, and recoverable flag instead of a bare
  `error` string.
* Position is delivered as `PlaybackPosition`, including buffered position and
  duration.
* Native namespace is now `io.github.aswinsubhash.native_feed_player`.

**Fixed**

* Controller lifetime is authoritative on the native side. Eviction is published
  as a lifecycle event and the Dart cache is derived from it, so
  `controllerFor` can no longer return a handle whose native player is gone.
  Commands on a released controller throw `ControllerReleasedError` instead of
  silently doing nothing.
* Window eviction no longer destroys controllers the moment they are created.
  Eviction runs after registration, skips controllers created since the last
  viewport update, and never selects the position being created.
* Android trim-memory levels are matched explicitly. They are not ordered by
  severity, so a `>=` comparison treated `TRIM_MEMORY_UI_HIDDEN` — an ordinary
  background transition — as critical and drained the whole player pool.
* A single budget now bounds live, preloaded, and pooled players together
  instead of capping each bucket while their sum grew freely.
* `NativeVideoView` binds through the controller's own platform rather than the
  global singleton, and retries attachment when the platform view is not ready.
* Controller ids come from a process-wide counter, so a re-attaching engine
  cannot collide with handles Dart still holds.
* iOS looping is gapless via `AVPlayerLooper`, replacing seek-to-zero.
* iOS surfaces structured setup error codes instead of a blanket
  `create_failed`.
* Unsupported platforms fail with `UnsupportedPlatformError` rather than
  `MissingPluginException`.

**Added**

* Disk caching with a 256 MB LRU budget. Android caches all formats via
  Media3 `CacheDataSource`; iOS caches progressive media via an
  `AVAssetResourceLoaderDelegate`. HLS is not disk-cached on iOS.
* Real prebuffering on iOS: in-window `AVPlayerItem`s with distance-scaled
  forward buffers and preroll for the immediate neighbour. Previously only asset
  metadata was loaded.
* Media3 `DefaultPreloadManager` on Android, preloading at the MediaSource level
  instead of keeping a whole ExoPlayer per upcoming item.
* Direction-aware preload windowing with concurrency caps, duplicate-URI
  collapsing, and self-limiting degradation under sustained stalling.
* Playback controls: `setVolume`, `setMuted`, `setPlaybackSpeed`, `setLooping`,
  plus a global `AudioPolicy` with audio session and focus handling. Feeds
  default to muted.
* Playback pauses when the app backgrounds and restores what was interrupted.
* UI data: `videoSizeStream`, `firstFrameRendered`, buffered position, duration.
  `NativeVideoView` gains `fit` and `placeholder`.
* Optional Texture rendering via `RenderMode.texture`. The default remains
  platform views pending the benchmark in `doc/RENDERING_BENCHMARK.md`.
* Per-source HTTP headers.
* Typed Pigeon event channels for state, position, metrics, video size, and
  lifecycle.
* 49 Dart tests, 25 Kotlin tests, 15 Swift tests, and GitHub Actions CI.

**Changed**

* Metrics mean the same thing on both platforms: first-frame latency is measured
  to the first rendered frame, and dropped frames are a lifetime total.
* Position events are only emitted for controllers that render or play.
* Media3 upgraded from 1.4.1 to 1.11.0.
* `docs/` renamed to `doc/` to match the pub layout convention.

## 0.0.1

* Scaffolded Flutter plugin for iOS and Android.
* Added feed-oriented Dart API:
  * `NativeFeedPlayer.initialize`
  * `NativeFeedPlayer.preload`
  * `NativeFeedPlayer.getController`
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
  * Added native metrics channel (`native_feed_player/metrics`) on Android/iOS
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
* Added release benchmark workflow assets:
  * Integration tests now emit structured `NFP_BENCHMARK_SUMMARY` lines
  * Added `tool/benchmark_report.dart` for log-to-markdown summaries
  * Added device matrix report template and benchmark runbook docs
* Added architecture and implementation backlog docs.
