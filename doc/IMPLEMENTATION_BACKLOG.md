# Native Feed Player Backlog

## Milestone 1: Baseline Plugin and API

- [x] Scaffold Flutter plugin (`android` + `ios`) and example app.
- [x] Define Dart API for:
  - initialization
  - preload scheduling
  - controller creation/lifecycle
  - playback commands
- [x] Add native method stubs so API calls do not return `notImplemented`.
- [x] Add Pigeon contract generation to replace raw method strings.

**Acceptance criteria**
- Package builds in Flutter.
- Example app runs and can call initialize/preload/controller methods without native exceptions.

## Milestone 2: Native Playback MVP

- [x] iOS: Implement `AVPlayer` playback for a single controller.
- [x] Android: Implement Media3 `ExoPlayer` playback for a single controller.
- [x] Wire playback state events (`ready`, `playing`, `paused`, `buffering`, `error`).
- [x] Wire position events with throttled updates (e.g. 200ms).

**Acceptance criteria**
- Start/pause/seek work on both platforms for one video.
- Dart `stateStream` and `positionStream` receive updates.
- Note: video rendering surface/widget is still tracked in Milestone 5.

## Milestone 3: Pre-buffering

- [x] iOS: preload `AVAsset` keys (`playable`, `duration`) in background.
- [x] Android: preload media with `prepare()` and tuned `LoadControl`.
- [x] Add configurable preload window around current index.
- [x] Implement cancellation for stale preload requests during fast flings.

**Acceptance criteria**
- Adjacent video starts in <150ms after scroll settle (Wi-Fi baseline).
- Spinner rate is significantly lower than `video_player` baseline.
- Benchmark validation still pending on physical device matrix.

## Milestone 4: Memory and Pooling

- [x] Add index-aware player pool with configurable max size.
- [x] Auto-evict controllers outside active window.
- [x] Recycle rendering targets to avoid frequent surface/layer recreation.
- [x] Add low-memory handling hooks:
  - iOS memory warnings
  - Android trim memory callbacks

**Acceptance criteria**
- No steady memory growth during 10+ minute continuous scroll test.
- No crashes on low-end device profile test matrix.
- Surface/layer recycling now uses pooled render targets on both platforms.

## Milestone 5: Platform View Rendering

- [x] iOS: `UIView` + `AVPlayerLayer` factory registration.
- [x] Android: `PlatformView` with `SurfaceView` or `TextureView`.
- [x] Dart `NativeVideoView` widget binding.
- [x] Attach/detach player on list item lifecycle changes.

**Acceptance criteria**
- Video renders inside Flutter list/grid cells.
- Scroll remains smooth when rapidly changing visible index.
- Full feed-level smoothness benchmarking still pending.

## Milestone 6: Production Hardening

- [x] Add instrumentation:
  - first-frame latency
  - rebuffer count
  - dropped frame estimates
- [x] Add integration tests for:
  - fast fling
  - pause/resume app
  - network loss/recovery
- [x] Prepare public docs and publish checklist.

**Acceptance criteria**
- CI checks pass for package + example build smoke tests.
- README includes clear limitations and tuning guidance.
- Physical device-matrix smoke runs remain a release gate.

## Known Issues

- [ ] **iOS unit-test host crashes at teardown.** Every `RunnerTests` case
  passes, but the Flutter Runner test host exits with
  `Early unexpected exit ... Crash: Runner at <external symbol>` after the
  final case in a suite, so `xcodebuild test` reports failure regardless of
  results. The CI step is marked `continue-on-error` until this is fixed, and
  must be made blocking afterwards.
- [ ] **Rendering default is unmeasured.** `RenderMode.platformView` is the
  default because it is the exercised path, not because it won a benchmark.
  `doc/RENDERING_BENCHMARK.md` holds the procedure and the table to fill from
  physical devices.
- [ ] **HLS is not disk-cached on iOS.** AVFoundation resolves playlists and
  segments internally, so the resource-loader cache only covers progressive
  media. Android caches both.
- [ ] **Plugin still applies the Kotlin Gradle Plugin.** Flutter's migrator
  re-adds `android.builtInKotlin=false` / `android.newDsl=false` on every
  build; migrating the plugin to built-in Kotlin removes the opt-out.
