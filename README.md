# native_feed_player

Native video playback for scrollable Flutter feeds.

Playback runs on `AVPlayer` (iOS) and Media3 `ExoPlayer` (Android). The plugin
owns the parts a feed actually needs and that a plain video player does not:
deciding what to prepare next, keeping player count bounded, caching bytes to
disk, and reporting whether any of it is working.

## Status

Under active development. The API is not yet stable and breaking changes should
be expected before 1.0.

What works today:

- Sources addressed by caller-owned stable ids, so pagination never renumbers
  or invalidates the feed
- Direction-aware preload scheduling that follows travel, caps concurrency,
  collapses repeated URIs, and shrinks itself under sustained stalling
- Android prebuffers nearby media bytes; iOS prepares items but starts loading
  only when a live controller adopts them
- Disk caching with a 256 MB LRU budget (Android: all formats; iOS: progressive
  media only, see [Caching](#caching))
- Player pooling with a single global budget and window-based eviction
- Typed commands and typed event streams over Pigeon
- Structured playback errors with a recoverable flag
- Playback controls: volume, mute, speed, looping, plus audio session and focus
  policy
- Data for real UI: duration, buffered position, video size, first-frame signal
- Platform-view rendering, with a Texture path available behind a flag
- First-frame latency, rebuffer count, and dropped-frame metrics

## Quick start

```dart
import 'package:native_feed_player/native_feed_player.dart';

final player = FeedPlayer();

await player.initialize();

await player.setSources(<FeedSource>[
  FeedSource(id: 'clip-1', uri: 'https://example.com/one.mp4'),
  FeedSource(id: 'clip-2', uri: 'https://example.com/two.mp4'),
]);

// Publish the viewport first so the scheduler ranks preloading around it.
await player.setVisibleSource('clip-1');

final controller = await player.controllerFor('clip-1');
await controller.play();
```

Render it:

```dart
NativeVideoView(
  controller: controller,
  fit: BoxFit.cover,
  placeholder: const ColoredBox(color: Colors.black),
);
```

Append a page without disturbing anything already loaded:

```dart
await player.appendSources(<FeedSource>[
  FeedSource(id: 'clip-3', uri: 'https://example.com/three.mp4'),
]);
```

## Controller lifetime

**Native code owns controller lifetime.** The scheduler reclaims players when
they fall outside the active window or memory gets tight, so a controller can
die without you asking. This is the single most important thing to understand
about the API.

Only one native playback session is active per Flutter engine. Initializing a
new `FeedPlayer` releases controllers and outputs from the previous session,
including after a Flutter hot restart. Calling `dispose()` is terminal for that
`FeedPlayer`; create a new instance for a later session.

Controllers therefore fail loudly rather than silently:

```dart
if (controller.isReleased) {
  controller = await player.controllerFor(sourceId); // rebuild
}

// Commands on a released controller throw rather than doing nothing.
try {
  await controller.play();
} on ControllerReleasedError {
  // Reclaimed between the check and the call.
}

// Or react when it happens.
final reason = await controller.onReleased;
```

`controllerFor` always returns a live controller, rebuilding if the previous one
was reclaimed.

## Configuration

```dart
await player.initialize(
  config: const FeedPlayerConfig(
    maxActivePlayers: 3,
    preloadAhead: 2,
    preloadBehind: 1,
    maxConcurrentPreloads: 2,
    cache: CachePolicy(maxBytes: 256 * 1024 * 1024),
    audio: AudioPolicy(muted: false),
  ),
);
```

| Option | Default | Notes |
| --- | --- | --- |
| `maxActivePlayers` | `3` | Live controllers. Drop to `2` on low-memory devices. |
| `preloadAhead` | `2` | Positions prepared ahead of travel. Raise only after measuring memory and startup latency. |
| `preloadBehind` | `1` | Positions kept behind, for backwards scrolling. |
| `maxConcurrentPreloads` | `2` | Stops a fling from saturating the network with work that is about to go stale. |
| `positionUpdateInterval` | `200 ms` | Position events are only emitted for controllers that render or play. |
| `renderMode` | `platformView` | See [Rendering](#rendering). |
| `cache.maxBytes` | `256 MB` | LRU. Conservative so it stays safe on low-storage devices. |
| `audio.muted` | `false` | Set to `true` for feeds that should start silently. |
| `audio.handleAudioFocus` | `true` | Requests appropriate platform audio focus while playback is audible. |
| `audio.manageAudioSession` | `true` | iOS only. When `false`, the plugin never reconfigures `AVAudioSession`; the host app owns category, mode, and activation. |

Invalid tuning is rejected with `ArgumentError` in debug and release builds.
Call `setVisibleSource` only with a registered source id, on scroll settle (or
throttled during scroll), so the scheduler can infer direction and rank work
correctly.

## Caching

Cached bytes are reused across sessions, so a second pass over a feed avoids the
network. Cache entries are partitioned by a SHA-256 identity derived from the URI
and canonical request headers. Raw authorization headers are never stored in
cache keys or metadata; rotating a token intentionally creates a new partition.

Sources whose URIs carry volatile query parameters (signed or expiring URLs) can
opt out of that partitioning with `FeedSource.cacheKey`: when set, it replaces
the URI in the identity so every rotation of the signature shares one cache
entry. Headers remain part of the identity either way. Changing `cacheKey`
changes the source's identity, so `setSources` releases and re-creates any live
controller for it — the same treatment as a `uri` change.

```dart
FeedSource(
  id: 'clip-1',
  uri: 'https://cdn.example.com/one.mp4?sig=rotating-token',
  cacheKey: 'clip-1',
)
```

```dart
await player.cacheUsageBytes();
await player.cacheStatus('clip-1');
await player.evictCachedMedia(<String>['clip-1']);
await player.clearMediaCache();
```

**The two platforms are not equivalent, and this is a real limitation:**

| | Android | iOS |
| --- | --- | --- |
| Progressive (mp4/mov) | Cached | Cached |
| HLS | Cached | **Not cached** |

Authenticated iOS HLS must use signed URLs or cookies. Custom `FeedSource.headers`
are rejected for HLS because AVFoundation exposes no public API that guarantees
those headers on every playlist and segment request.

Android caches through Media3's `CacheDataSource`, which sits below format
handling. Per-source headers are applied to progressive files and every HLS
playlist, segment, and key request. iOS caches through an
`AVAssetResourceLoaderDelegate`, and
AVFoundation resolves HLS playlists and segments internally where a
resource-loader shim cannot reach them. HLS on iOS plays from the network with a
tuned forward buffer instead.

On iOS, cache entries are whole files rather than byte ranges, and a seek past
the downloaded prefix waits for the sequential download to reach it. This suits
short clips played front to back; it is a poor fit for long-form seeking.

## Rendering

```dart
// Default: a native view composited by Flutter's platform-view layer.
FeedPlayerConfig(renderMode: RenderMode.platformView)

// Alternative: frames drawn by the Flutter renderer.
FeedPlayerConfig(renderMode: RenderMode.texture)
```

`NativeVideoView` must be told the same mode the player was initialized with:

```dart
NativeVideoView(controller: controller, renderMode: player.config.renderMode);
```

Sizing is adaptive by default: portrait and square videos use `BoxFit.cover`,
while landscape videos use `BoxFit.contain` so the complete frame stays centered.
Pass `fit: BoxFit.cover` or `fit: BoxFit.contain` to override that decision.

`platformView` is the default because it is the exercised path, **not** because
it won a benchmark. Which mode is faster depends on GPU bandwidth, refresh rate,
and video resolution, and the iOS texture path pays a per-frame pixel-buffer
copy. See [`doc/RENDERING_BENCHMARK.md`](doc/RENDERING_BENCHMARK.md) for the
procedure and the table to fill from real devices.

## Metrics

Both platforms report the same definitions, so numbers are comparable:

- `firstFrameLatency` — controller creation to the first frame actually
  rendered
- `rebufferCount` — stalls after playback first became ready
- `droppedFrames` — lifetime total, not a per-sample delta

```dart
controller.metricsStream.listen((m) => print(m.firstFrameLatency));
```

## Limitations

- HLS is not disk-cached on iOS (see [Caching](#caching)).
- iOS HLS sources with custom headers are rejected; use signed URLs or cookies.
- The default render mode is unmeasured (see [Rendering](#rendering)).
- No DRM, subtitles, or explicit track-selection APIs.
- Android and iOS only; other platforms throw `UnsupportedPlatformError`.
- iOS does not prebuffer media bytes before a live controller is created.
- iOS long-form seeking is weak while a clip is still downloading.
- Physical-device performance validation is still an open release gate.

Tracked in [`doc/IMPLEMENTATION_BACKLOG.md`](doc/IMPLEMENTATION_BACKLOG.md).

## Pigeon contracts

Commands and events are generated. After editing
`pigeons/native_feed_player_messages.dart`:

```bash
dart run tool/generate_pigeon.dart
```

CI regenerates and fails if the tree changes, since stale generated code is a
silent source of platform drift.

## Docs

- [Architecture](doc/ARCHITECTURE.md)
- [Rendering benchmark](doc/RENDERING_BENCHMARK.md)
- [Benchmark workflow](doc/BENCHMARK_WORKFLOW.md)
- [Release checklist](doc/RELEASE_CHECKLIST.md)
- [Backlog and known issues](doc/IMPLEMENTATION_BACKLOG.md)

## Requirements

- Flutter 3.47+, Dart 3.13+
- Android: minSdk 24, Media3 1.11, AGP built-in Kotlin
- iOS: 15.0+, with CocoaPods and Swift Package Manager support
