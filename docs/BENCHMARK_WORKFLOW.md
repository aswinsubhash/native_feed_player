# Benchmark Workflow

This workflow produces reproducible scenario metrics for the release device matrix.

## 1. Run integration benchmark on a physical device

From `/Users/aswinsubhash/Documents/New project/native_reels_player/example`:

```bash
flutter test integration_test/plugin_integration_test.dart -d <device-id> | tee benchmark_<device-id>.log
```

The integration tests emit structured lines like:

`NRP_BENCHMARK_SUMMARY {"scenario":"fast_fling", ...}`

## 2. Convert log to markdown summary

From `/Users/aswinsubhash/Documents/New project/native_reels_player`:

```bash
dart run tool/benchmark_report.dart \
  --log example/benchmark_<device-id>.log \
  --device "<device name>" \
  --os "<os version>" \
  --variant "release" \
  --out docs/device-matrix/<device-id>.md
```

Use `--append` if you want to keep adding runs to the same report file.

## 3. Fill release template

Start from:

- `docs/DEVICE_MATRIX_REPORT_TEMPLATE.md`

Then paste each per-device summary table and mark pass/fail for:

- fast fling churn
- pause/resume app
- network loss/recovery
