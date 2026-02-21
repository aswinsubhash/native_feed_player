# Device Matrix Report (Emulator)

## Build Metadata

- Release tag: `emulator-matrix-2026-02-21`
- Commit: `620e404`
- Package version: `0.0.1`
- Build date (UTC): `2026-02-21T01:19:39Z`

## Device Matrix

| Platform | Device | OS | Network | Build Variant | Result |
| --- | --- | --- | --- | --- | --- |
| Android | sdk gphone64 arm64 (emulator-5554) | Android 16 (API 36) | Simulated | debug | pass |
| iOS | iPhone 17 Pro (simulator) | iOS 26.2 | Simulated | debug | pass |

## Scenario Results

| Scenario | Pass/Fail | Notes |
| --- | --- | --- |
| fast fling churn | pass | Both emulator targets passed test flow without crashes. |
| pause/resume app | pass | Lifecycle transitions handled correctly on both emulator targets. |
| network loss/recovery | pass | Both targets recovered; iOS simulator run took longer due timeout/retry behavior. |

## Metrics Summary (from `tool/benchmark_report.dart`)

| Device | Scenario | Duration (s) | Metric Samples | First Frame P50 (ms) | First Frame P95 (ms) | Max Rebuffer | Max Dropped Frames |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| sdk gphone64 arm64 (emulator-5554) | fast_fling | 1.69 | 0 | 0 | 0 | 0 | 0 |
| sdk gphone64 arm64 (emulator-5554) | pause_resume | 1.27 | 0 | 0 | 0 | 0 | 0 |
| sdk gphone64 arm64 (emulator-5554) | network_recovery | 1.46 | 0 | 0 | 0 | 0 | 0 |
| iPhone 17 Pro (simulator) | fast_fling | 1.62 | 0 | 0 | 0 | 0 | 0 |
| iPhone 17 Pro (simulator) | pause_resume | 1.25 | 0 | 0 | 0 | 0 | 0 |
| iPhone 17 Pro (simulator) | network_recovery | 15.12 | 0 | 0 | 0 | 0 | 0 |

## Observations

- Functional scenario coverage passed on both emulator targets.
- Metric sample counts are `0` for all scenarios on emulators, so timing/rebuffer/dropped-frame conclusions are not production-grade.
- iOS simulator network recovery path shows much higher wall-clock duration than Android emulator under the same test logic.

## Release Decision

- Ship / Hold: `Hold`
- Reason: Emulator matrix is green functionally, but release criteria still require physical device matrix and non-zero metric collection for performance validation.
