# native_reels_player

Flutter plugin for reels-style video playback with native playback control,
state/position streams, and pre-buffering scaffolding on iOS and Android.

## Status

Current state:

- Dart API is implemented (`initialize`, `preload`, controllers, playback methods).
- iOS/Android native playback managers are implemented for a single controller.
- Native `state` and `position` events are emitted and mapped to Dart streams.
- Native pre-buffering now uses visible-index windowing and stale-request cancellation.
- Platform view rendering (`NativeVideoView`) is not implemented yet.

See `docs/IMPLEMENTATION_BACKLOG.md` for the full roadmap.

## Quick Start

```dart
import 'package:native_reels_player/native_reels_player.dart';

final player = NativeReelsPlayer();

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

- `NativeReelsPlayer.initialize(...)`
- `NativeReelsPlayer.preload(List<String>)`
- `NativeReelsPlayer.getController(...)`
- `NativeReelsPlayer.setVisibleIndex(int)`
- `NativeReelsPlayer.clearCache()`
- `NativeReelsPlayer.dispose()`

`VideoController`:

- `play()`
- `pause()`
- `seekTo(Duration)`
- `positionStream`
- `stateStream`
- `dispose()`

## Architecture

- Dart facade + platform interface + method channel implementation.
- Native plugin entry points on iOS/Android with `EventChannel` streams.
- Real native managers (`AVPlayerManager`, `ExoPlayerManager`) for playback lifecycle.
- `VideoPool` placeholders reserved for broader pooling milestones.

Detailed architecture: `docs/ARCHITECTURE.md`
