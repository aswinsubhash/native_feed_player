# native_feed_player_example

Demonstrates feed-oriented native video playback, both render modes, controller
lifecycle handling, preloading, caching, and playback metrics.

## Run

```bash
flutter run
```

Native integration tests use `assets/test_clip.mp4`, a one-second low-quality
transcode of Flutter's standard gallery bee video, served from an in-process
range-capable HTTP server so playback does not depend on external networking.

```bash
flutter test integration_test/plugin_integration_test.dart -d <device-id>
```
