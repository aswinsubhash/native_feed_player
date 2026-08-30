# Release Checklist

## Pre-Release Validation

- [ ] `dart format --output=none --set-exit-if-changed` passes for committed Dart sources.
- [ ] `flutter analyze` passes at package root.
- [ ] `flutter test` passes at package root and in `example/`.
- [ ] `dart run tool/generate_pigeon.dart` leaves all committed bindings unchanged.
- [ ] `dart doc` completes without warnings.
- [ ] `flutter build apk --debug` passes in `example/`.
- [ ] Android plugin unit tests and `lintDebug` pass under built-in Kotlin.
- [ ] Android and iOS simulator integration jobs pass for both render modes.
- [ ] CocoaPods-mode `flutter build ios --simulator --no-codesign` passes in `example/`.
- [ ] SwiftPM-mode `flutter build ios --simulator --no-codesign` passes in `example/`.
- [ ] Swift plugin unit tests pass through both CocoaPods and SwiftPM integration.
- [ ] Hot restart at least three consecutive times on Android and iOS; after each restart, scroll every source and verify visible video, matching audio, advancing position, and state transitions out of `preparing`.
- [ ] Repeat the hot-restart check once with `RenderMode.texture`.
- [ ] Strict `pod lib lint` passes without allowing warnings.
- [ ] `example/pubspec.lock` and `example/ios/Podfile.lock` are current.
- [ ] Run integration tests on at least one Android and one iOS physical device:
  - fast fling churn
  - app pause/resume
  - network loss/recovery
- [ ] Generate benchmark summaries from device logs using:
  - `tool/benchmark_report.dart`
  - `doc/BENCHMARK_WORKFLOW.md`
  - `doc/DEVICE_MATRIX_REPORT_TEMPLATE.md`

## Playback Quality Gates

- [ ] Capture first-frame latency samples (cold/warm cache).
- [ ] Capture rebuffer counts during 3-5 minute scroll sessions.
- [ ] Capture dropped-frame estimates during rapid scroll and resume.
- [ ] Verify no sustained memory growth during 10+ minute feed run.

## Package Quality

- [ ] Update `CHANGELOG.md` with release highlights.
- [ ] Ensure README documents:
  - API surface and examples
  - tuning guidance
  - limitations and known caveats
- [ ] Confirm Flutter 3.47, Dart 3.13, iOS, and Android requirements are explicit.
- [ ] Verify authenticated cache partitions never persist raw header values.
- [ ] Confirm `LICENSE` contains the intended canonical license text and is recognized by package tooling.
- [ ] Confirm native builds contain no package-owned compiler warnings.
- [ ] Confirm CocoaPods and SwiftPM bundle `PrivacyInfo.xcprivacy`.

## Pub.dev Publishing

- [ ] Set `homepage`, `repository`, and issue tracker links in `pubspec.yaml`.
- [ ] Set semantic `version` in `pubspec.yaml`.
- [ ] Confirm the matching `v<version>` repository tag exists for the CocoaPods source declaration.
- [ ] Ensure example app has version/build values for iOS archive compliance.
- [ ] Run `flutter pub publish --dry-run` and inspect the archive contents.
- [ ] Publish when all gates above are green.
