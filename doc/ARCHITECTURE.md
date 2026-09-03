# Architecture Overview

## Guiding rules

1. **Native owns the truth.** Every native lifecycle transition, including
   eviction the app did not ask for, is published as a typed event. Dart state
   is derived from those events, never assumed.
2. **Sources are identified by stable id, never by position.** Feed position is
   a ranking hint for preload priority and eviction distance, nothing more.
3. **One scheduler per platform** owns preload, eviction, and cache priming, so
   the policy lives in one place instead of being spread across create, preload,
   and viewport calls.
4. **Everything injectable**, so the Dart layer is testable without a device.

## Package layout

```
native_feed_player/
├── pigeons/
│   └── native_feed_player_messages.dart   # commands + typed event channels
├── lib/
│   ├── native_feed_player.dart            # public exports
│   ├── native_feed_player_platform_interface.dart
│   ├── native_feed_player_method_channel.dart
│   └── src/
│       ├── messages.g.dart                # generated
│       ├── native_feed_player_api.dart    # FeedPlayer facade
│       ├── video_controller.dart          # FeedController
│       ├── native_video_view.dart         # platform view | Texture
│       ├── feed_source.dart
│       ├── feed_player_config.dart
│       ├── controller_release.dart
│       ├── playback_error.dart
│       ├── video_metrics.dart
│       ├── video_playback_state.dart
│       └── video_size.dart
├── android/src/main/kotlin/io/github/aswinsubhash/native_feed_player/
│   ├── NativeFeedPlayerPlugin.kt           # host API + event sinks + lifecycle
│   ├── ExoPlayerManager.kt                 # playback, eviction, budget
│   ├── FeedSourceRegistry.kt               # ids, ranks, window arithmetic
│   ├── FeedPreloadManager.kt               # Media3 DefaultPreloadManager
│   ├── MediaCache.kt                       # SimpleCache + data source chain
│   ├── PlaybackErrorMapper.kt
│   ├── TextureOutputRegistry.kt            # SurfaceTexture output
│   ├── TextureViewPool.kt
│   ├── EventSinks.kt
│   └── Messages.g.kt                       # generated
└── ios/native_feed_player/
    ├── Package.swift                       # SwiftPM manifest
    └── Sources/native_feed_player/         # shared by SwiftPM and CocoaPods
        ├── NativeFeedPlayerPlugin.swift    # host API + event sinks
        ├── AVPlayerManager.swift           # playback, eviction, budget
        ├── FeedSourceRegistry.swift        # ids, ranks, window arithmetic
        ├── MediaDiskCache.swift            # LRU file store
        ├── CachingResourceLoader.swift     # resource loader + download
        ├── PlaybackErrorMapper.swift
        ├── VideoOutputTexture.swift        # FlutterTexture output
        ├── RenderViewPool.swift
        ├── FileHandleCompat.swift
        ├── PrivacyInfo.xcprivacy
        └── Messages.g.swift                # generated
```

## Layers

```
FeedPlayer                     facade: sources, controllers, cache queries
  └── FeedController           per-source handle, lifecycle-aware
        └── FeedPlayerPlatform injected everywhere
              ├── HostApi          typed commands (Pigeon)
              └── EventChannelApi  typed state/position/metrics/videoSize/lifecycle
                    ├── Android: ExoPlayerManager
                    │     ├── FeedSourceRegistry
                    │     ├── FeedPreloadManager  (Media3, MediaSource-level)
                    │     ├── MediaCache          (SimpleCache + CacheDataSource)
                    │     └── output: TextureView | SurfaceTexture
                    └── iOS: AVPlayerManager
                          ├── FeedSourceRegistry
                          ├── prebuffering        (AVPlayerItem + preroll)
                          ├── CachingResourceLoader + MediaDiskCache
                          └── output: AVPlayerLayer | AVPlayerItemVideoOutput
```

## Scheduling

The registry keys sources by id and stores a rank. From successive viewport
updates it infers a scroll direction, and the preload window follows travel:
`preloadAhead` is spent in the direction of movement and `preloadBehind` behind
it, swapping when the user scrolls backwards. Within the window, work is ordered
nearest-first, capped by `maxConcurrentPreloads`, and sources sharing a URI are
collapsed to the nearest occurrence.

Rebuffers accumulate within a bounded time window. At the threshold the preload
window halves down to a floor that still keeps the immediate neighbour prepared;
it recovers one step only after a sustained uninterrupted playback interval.
Critical memory pressure drops straight to the floor, clears prepared work, and
does not immediately reallocate: the OS provides no "pressure ended" signal, so
the window stays empty until the next feed interaction (viewport change,
controller creation, source mutation) or until sustained playback restores the
adaptive scale (about 30 s on Android, 15 s on iOS).

### Eviction

Two independent limits, plus a safety net:

- `maxActivePlayers` bounds live controllers. The victim is the one furthest
  from the viewport, never the position a controller is being created for.
- A global budget bounds live controllers plus pooled players together, trimming
  the stateless pool before touching anything live.
- Window eviction reclaims controllers that fall outside the window, but only
  once they have been measured against a viewport the app has actually
  published. Controllers created since the last `setVisibleSource` are exempt,
  because an app that prepares neighbours before publishing the new position
  would otherwise lose the very controller it just requested.

## Preloading and caching

**Android.** `DefaultPreloadManager` preloads at the MediaSource level, so a
nearby item costs a prepared source rather than a whole player. Target status
varies by distance: the immediate neighbour is buffered into memory, items
further out are cached to disk only. Every player is built from the preload
manager's builder so they share the load control, bandwidth meter, track
selector, and playback looper — a preloaded source is only valid on a player
from that builder, and the manager must be released before them.

Bytes flow through `CacheDataSource` over a `SimpleCache` with an LRU evictor.
Each source receives its own data-source context, so headers reach progressive
requests and every HLS playlist, segment, and key request. Cache keys are
partitioned by a versioned SHA-256 identity over URI and canonical headers; no
raw credential material is persisted.

**iOS.** In-window sources get dedicated muted, paused preload players with a
forward buffer scaled by distance; attaching the item is what makes AVFoundation
fetch and decode ahead. Once a preload player is ready it prerolls, and the live
controller creates a fresh item from the warmed asset because items cannot be
reused across players.
Progressive media plays through an `AVAssetResourceLoaderDelegate`
over a private URL scheme, which serves playback from one sequential download
while writing the same bytes to disk. Only complete 2xx responses are adopted
into the header-partitioned cache; cancellation and failed responses finish all
pending AVFoundation requests.

HLS is excluded from iOS caching: AVFoundation resolves playlists and segments
internally, out of reach of a resource-loader shim. HLS sources with custom
headers are rejected on iOS because no public AVFoundation API guarantees those
headers on every child request; callers must use signed URLs or cookies.

## Metrics

Defined identically on both platforms so numbers are comparable:

- **First-frame latency** — controller creation to the first frame actually
  rendered. Android uses `onRenderedFirstFrame`; iOS observes
  `AVPlayerLayer.isReadyForDisplay` rather than the earlier "started playing"
  transition.
- **Dropped frames** — a monotonic lifetime total. Android accumulates
  `onDroppedVideoFrames` deltas; iOS sums access-log events.
- **Rebuffer count** — stalls after playback first became ready.

## Events

One typed Pigeon event channel per concern: playback state (carrying a
structured `PlaybackError`), position (with buffered position and duration),
metrics, video size, and controller lifecycle. A small buffer holds events
emitted before Dart subscribes, because native playback starts reporting during
`createController`, before a caller can attach a listener.

Position events are only emitted for controllers that are rendering or playing,
rather than for every managed player on every tick.

## Rendering

Both backends are supported and selected by `FeedPlayerConfig.renderMode`:
platform views (a native view composited by Flutter) or textures
(`SurfaceTexture` on Android, `AVPlayerItemVideoOutput` copied into a
`FlutterTexture` on iOS). The default is provisional; see
`doc/RENDERING_BENCHMARK.md`.

## Next priorities

1. Fill the rendering benchmark table on physical devices and settle the
   default.
2. Run the physical device matrix with non-zero metric samples in both render
   modes.
3. Track authenticated cache growth across token rotation and long sessions.
