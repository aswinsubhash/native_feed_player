# native_feed_player

Flutter plugin for feed-oriented video playback with native playback control,
state/position streams, and pre-buffering scaffolding on iOS and Android.

## Status

Current state:

- Dart API is implemented (`initialize`, `preload`, controllers, playback methods).
- iOS/Android native playback managers are implemented for a single controller.
- Native `state` and `position` events are emitted and mapped to Dart streams.
- Native pre-buffering now uses visible-index windowing and stale-request cancellation.
- Native memory handling now includes index-aware player pooling and low-memory hooks.
- Native rendering uses `NativeVideoView` backed by platform views.
- Platform rendering targets (`TextureView`/`AVPlayerLayer` views) are recycled to reduce churn during fast scrolling.
- Native instrumentation now exposes:
  - first-frame latency
  - rebuffer count
  - dropped-frame estimate
- Command transport now uses generated Pigeon contracts for typed platform RPC.

See `docs/IMPLEMENTATION_BACKLOG.md` for the full roadmap.

## Quick Start

```dart
import 'package:native_feed_player/native_feed_player.dart';

final player = NativeFeedPlayer();

await player.initialize(maxCachedPlayers: 5, preloadCount: 2);
await player.preload(<String>[
  'https://example.com/video-1.mp4',
  'https://example.com/video-2.mp4',
]);

final controller = await player.getController(
  url: 'https://example.com/video-1.mp4',
  index: 0,
);

await controller.play();
```

## API Surface

- `NativeFeedPlayer.initialize(...)`
- `NativeFeedPlayer.preload(List<String>)`
- `NativeFeedPlayer.getController(...)`
- `NativeFeedPlayer.setVisibleIndex(int)`
- `NativeFeedPlayer.clearCache()`
- `NativeFeedPlayer.dispose()`

`VideoController`:

- `play()`
- `pause()`
- `seekTo(Duration)`
- `positionStream`
- `stateStream`
- `metricsStream`
- `dispose()`

Rendering widget:

- `NativeVideoView(controller: controller)`

## Architecture

- Dart facade + platform interface + method channel implementation.
- Native plugin entry points on iOS/Android with `EventChannel` streams.
- Real native managers (`AVPlayerManager`, `ExoPlayerManager`) for playback lifecycle.
- `VideoPool` placeholders reserved for broader pooling milestones.

Detailed architecture: `docs/ARCHITECTURE.md`

## Pigeon Contracts

- Source schema: `pigeons/native_feed_player_messages.dart`
- Generated outputs:
  - Dart: `lib/src/messages.g.dart`
  - Android: `android/src/main/kotlin/com/example/native_feed_player/Messages.g.kt`
  - iOS: `ios/Classes/Messages.g.swift`
- Regenerate after schema edits:

```bash
dart run pigeon \
  --input pigeons/native_feed_player_messages.dart \
  --dart_out lib/src/messages.g.dart \
  --kotlin_out android/src/main/kotlin/com/example/native_feed_player/Messages.g.kt \
  --kotlin_package com.example.native_feed_player \
  --swift_out ios/Classes/Messages.g.swift
```

## Tuning Guidance

- `maxCachedPlayers`:
  - Start at `5` for mid/high devices.
  - Reduce to `3` for low-memory devices.
- `preloadCount`:
  - Start at `2` for a video feed.
  - Increase to `3` only after measuring memory and startup latency impact.
- Use `setVisibleIndex(...)` on scroll settle (or throttled scroll updates) so native eviction/preload policy can stay in sync with the feed.

## Limitations

- Event channels currently use raw `MethodChannel`/`EventChannel` contracts (Pigeon migration is still pending).
- Rendering path is platform-view based; texture-only rendering is not implemented yet.
- DRM, subtitles/closed captions, and adaptive track-selection APIs are not exposed in Dart yet.
- Device-matrix performance benchmarking is still a release gate for production rollout.

## Release Process

- Milestone hardening and publish steps: `docs/RELEASE_CHECKLIST.md`
- Device benchmark runbook: `docs/BENCHMARK_WORKFLOW.md`
