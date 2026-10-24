## 0.1.0

Initial public release.

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
- Verify iOS cached file sizes against the index and evict truncated entries.
- Reference-count the Android media cache across Flutter engines and release it on engine detach.
- Drop pooled Android `TextureView`s when their activity is destroyed to prevent activity leaks.
- Reset recycled player speed, volume, and mute on both platforms.
- Replay the latest position to late `positionStream` subscribers.
- Declare the `INTERNET` permission in the Android library manifest.
- Implement iOS `detachFromEngine` and make teardown main-thread safe.
- Coordinate playback-session and output ownership so superseded players and widgets cannot tear down their replacements.
- Prevent unhandled first-frame release errors across Dart error zones while preserving future identity within each zone.
- Separate playback-request identity from disk-cache identity when signed URLs or request metadata change.
- Use rank-indexed preload windows and update retained Android preload rankings without replacing shared media sources.
- Report Android progressive cache completeness only when the current playback key has complete byte-range coverage.
- Load iOS loop metadata asynchronously and preserve playback and seek intent across configuration changes.
- Recover custom-loaded iOS playback from buffer starvation without overriding pause, background, release, or failure state.
- Resume after successful seeks without waiting for a position-update tick, and retain the latest seek across loop changes.
- Retain completed downloads on ordinary iOS request cancellation while preserving explicit cache eviction semantics.
- Deactivate plugin-owned iOS audio sessions and accumulate dropped-frame metrics across looping items.
- Render both output modes in integration benchmarks, count first frames once per controller, and reject incomplete benchmark data.

Known limitations: iOS does not disk-cache HLS or preload media bytes before a live controller adopts an item. Physical-device performance validation and the final rendering-default decision remain outstanding.
