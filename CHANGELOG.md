## Unreleased

- Keep source ranks dense after removals so later pages retain correct preload ordering.
- Wait for in-flight controller disposal before returning or rebuilding a controller.
- Bound iOS prepared items and release stale loader contexts with them.
- Reject partial iOS cache responses, convert MIME types to UTIs, and complete open-ended requests through EOF.
- Require Flutter 3.47, Dart 3.13, and iOS 15, with Android built-in Kotlin support.
- Isolate cached media by URI and canonical request headers without persisting credentials.
- Reject custom-header HLS on iOS in favor of App Store-safe signed URLs or cookies.
- Harden controller, texture, source, first-frame, and asynchronous cache lifecycles.
- Add blocking Android and iOS simulator integration coverage.
- Add `AudioPolicy.manageAudioSession` so host apps can keep ownership of `AVAudioSession` on iOS.
- Add `FeedSource.cacheKey` so signed or expiring URLs share one cache entry.
- Reject URIs without a scheme and non-positive playback speeds with `ArgumentError` before they reach native code.
- Move Android `SimpleCache` construction and iOS cache index loading off the platform main thread.
- Skip unplayable Android preload sources instead of crashing the main looper callback.
- Bound iOS resource-loader responses to fixed chunks so open-ended requests cannot read a whole cached file into memory.
- Serve iOS cached files to completion in bounded chunks on the same loading request.
- Reject iOS 206 responses that lack a client Range header instead of caching partial bodies as complete files.
- Verify iOS cached file sizes against the index and evict truncated entries.
- Reference-count the Android media cache across Flutter engines and release it on engine detach.
- Drop pooled Android `TextureView`s when their activity is destroyed to prevent activity leaks.
- Reset recycled player speed, volume, and mute on both platforms.
- Replay the latest position to late `positionStream` subscribers.
- Declare the `INTERNET` permission in the Android library manifest.
- Implement iOS `detachFromEngine` and make teardown main-thread safe.

## 0.1.0

Initial public release.
