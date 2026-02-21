# Architecture Overview

## Package Layout

```
native_reels_player/
├── lib/
│   ├── native_reels_player.dart
│   ├── native_reels_player_method_channel.dart
│   ├── native_reels_player_platform_interface.dart
│   └── src/
│       ├── native_reels_player_api.dart
│       ├── video_controller.dart
│       ├── video_metrics.dart
│       ├── video_models.dart
│       └── video_playback_state.dart
├── android/src/main/kotlin/com/example/native_reels_player/
│   ├── NativeReelsPlayerPlugin.kt
│   ├── ExoPlayerManager.kt
│   └── VideoPool.kt
└── ios/Classes/
    ├── NativeReelsPlayerPlugin.swift
    ├── AVPlayerManager.swift
    └── VideoPool.swift
```

## Dart Layer

- `NativeReelsPlayer`
  - package entry point for configure/preload/controller lifecycle.
  - caches `VideoController` by `(index, url)` key.
- `VideoController`
  - control object for play/pause/seek/dispose.
  - exposes `stateStream`, `positionStream`, and `metricsStream`.
- `NativeReelsPlayerPlatform`
  - contract for platform implementations.
- `MethodChannelNativeReelsPlayer`
  - method channel commands + shared event stream fan-out per controller.

## Native Layer (Current)

- `NativeReelsPlayerPlugin`
  - receives method channel commands and owns event channel sinks.
  - creates per-controller IDs and delegates to platform manager.
  - owns platform view registration and view/controller attachment.
- `ExoPlayerManager` / `AVPlayerManager`
  - owns real single-controller native playback lifecycle.
  - emits playback state and periodic position updates to Flutter.
  - emits playback metrics (first frame latency, rebuffers, dropped frames).
  - manages visible-index preload windows and stale-preload cancellation.
  - reuses pooled native players and reacts to low-memory signals.
- `VideoPool`
  - still a placeholder for advanced pooling milestones.

## Control Flow

1. Flutter calls `initialize(maxCachedPlayers, preloadCount)`.
2. Flutter calls `preload(urls)` as feed data becomes available.
3. Flutter requests `getController(url, index)` for visible or near-visible items.
4. User actions call `play/pause/seekTo` on each controller.
5. Native side emits state/position/metrics events back to Flutter.

## Next Implementation Priorities

1. Replace raw channels with Pigeon-generated API contracts.
2. Expand from single-controller flow to pool/window eviction policy tuning.
3. Harden pre-buffering behavior and cancellation across fast flings.
4. Automate benchmark runs and reporting for scroll smoothness metrics.
