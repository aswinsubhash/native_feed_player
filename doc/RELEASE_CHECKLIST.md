# Release Checklist

## Pre-Release Validation

- [ ] `flutter analyze` passes at package root.
- [ ] `flutter test` passes at package root.
- [ ] `flutter build apk --debug` passes in `example/`.
- [ ] `flutter build ios --no-codesign` passes in `example/`.
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
- [ ] Confirm iOS and Android platform requirements are explicit.

## Pub.dev Publishing

- [ ] Set `homepage`, `repository`, and issue tracker links in `pubspec.yaml`.
- [ ] Set semantic `version` in `pubspec.yaml`.
- [ ] Ensure example app has version/build values for iOS archive compliance.
- [ ] Run `flutter pub publish --dry-run`.
- [ ] Publish when all gates above are green.
