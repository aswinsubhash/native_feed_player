# Rendering Benchmark

`native_feed_player` supports two ways of getting native video into the Flutter
scene. Both are implemented and supported; this document is how the default is
chosen, and it must be filled in from real devices before that choice is
considered settled.

## The two modes

| Mode | How it works | Expected trade-off |
| --- | --- | --- |
| `RenderMode.platformView` | A native `TextureView` (Android) or `AVPlayerLayer` view (iOS) is composited into the Flutter scene by the platform-view layer. | Most compatible. Compositing costs a synchronisation step per frame, which tends to show up as jank during fast scrolling. |
| `RenderMode.texture` | Frames are rendered into a `SurfaceTexture` (Android) or copied via `AVPlayerItemVideoOutput` into a `FlutterTexture` (iOS) and drawn by the Flutter renderer. | Usually smoother while scrolling. iOS pays a per-frame pixel-buffer copy driven by `CADisplayLink`, which can cost CPU on older devices. |

The current default is `platformView`, because it is the mode that has actually
been exercised. **That default is provisional and should be revisited with the
numbers below.**

Selecting a mode:

```dart
await player.initialize(
  config: const FeedPlayerConfig(renderMode: RenderMode.texture),
);

// The widget must be told the same mode the player was initialized with.
NativeVideoView(
  controller: controller,
  renderMode: player.config.renderMode,
);
```

## Why this is measured rather than assumed

The usual advice is "textures are faster than platform views", but that depends
on GPU memory bandwidth, display refresh rate, and video resolution. On a
high-refresh device with a fast GPU the per-frame copy on iOS can cost more than
the compositing step it replaces, while on a mid-range Android device the
opposite is typically true. A single default across both platforms and all
device classes is unlikely to be right, so the numbers decide.

## Procedure

Run each scenario on each device, once per render mode.

### 1. Functional and metric pass

From `example/`:

```bash
flutter test integration_test/plugin_integration_test.dart \
  -d <device-id> | tee benchmark_<device>_<mode>.log
```

Convert to a table:

```bash
dart run tool/benchmark_report.dart \
  --log example/benchmark_<device>_<mode>.log \
  --device "<device name>" \
  --os "<os version>" \
  --variant "<mode>" \
  --out docs/device-matrix/<device>-<mode>.md
```

### 2. Scroll smoothness

Frame timing is what separates the two modes, and the integration tests do not
capture it. Run the example in profile mode and fling through the feed for at
least 30 seconds:

```bash
flutter run --profile -d <device-id>
```

Record from the DevTools performance view, or from the timeline summary:

- average and 99th-percentile frame build time
- average and 99th-percentile raster time
- count of frames over the device's budget (16.7 ms at 60 Hz, 8.3 ms at 120 Hz)

Raster time is the number that matters here: compositing and texture upload both
land on the raster thread.

### 3. Memory

Sample steady-state memory after five minutes of continuous scrolling, using
DevTools' memory view or `adb shell dumpsys meminfo <package>`.

## Results

Fill one row per device and mode. A mode should only become the default once it
wins on at least one low-end and one high-end device for that platform.

| Platform | Device | OS | Mode | First frame P50 (ms) | First frame P95 (ms) | Raster P99 (ms) | Frames over budget | Steady memory (MB) |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Android | _low-end device_ | | platformView | | | | | |
| Android | _low-end device_ | | texture | | | | | |
| Android | _high-end device_ | | platformView | | | | | |
| Android | _high-end device_ | | texture | | | | | |
| iOS | _iPhone_ | | platformView | | | | | |
| iOS | _iPhone_ | | texture | | | | | |

## Decision

- Android default: _pending measurement_
- iOS default: _pending measurement_
- Rationale: _record why, including any device where the losing mode was
  materially better, since that is the case a per-platform default has to
  justify._

Until this table is filled in, `platformView` remains the default on both
platforms and the texture path is opt-in.
