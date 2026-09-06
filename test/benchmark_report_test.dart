import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../tool/benchmark_report.dart' as benchmark_report;

String _summaryLine(Map<String, Object?> payload) =>
    'NFP_BENCHMARK_SUMMARY ${jsonEncode(payload)}';

Map<String, Object?> _validPayload({
  String scenario = 'fast_fling',
  String renderMode = 'platformView',
}) => <String, Object?>{
  'scenario': scenario,
  'renderMode': renderMode,
  'durationMs': 12345,
  'metricSamples': 10,
  'trackedControllers': scenario == 'fast_fling' ? 8 : 1,
  'firstFrameSamples': scenario == 'fast_fling' ? 5 : 1,
  'firstFrameP50Ms': 120,
  'firstFrameP95Ms': scenario == 'fast_fling' ? 260 : 120,
  'maxRebufferCount': 2,
  'maxDroppedFrames': 7,
  'timestampMs': 1700000000000,
};

List<String> _completeRun({Map<String, Object?>? firstPayload}) => <String>[
  _summaryLine(firstPayload ?? _validPayload()),
  for (final String scenario in <String>[
    'fast_fling',
    'pause_resume',
    'network_recovery',
  ])
    for (final String mode in <String>['platformView', 'texture'])
      if (scenario != 'fast_fling' || mode != 'platformView')
        _summaryLine(_validPayload(scenario: scenario, renderMode: mode)),
];

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nfp_benchmark_report');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File logFile(String name, List<String> lines) {
    final File file = File('${tempDir.path}/$name');
    file.writeAsStringSync('${lines.join('\n')}\n');
    return file;
  }

  (int, String, String) run(List<String> args) =>
      benchmark_report.runBenchmarkReport(args);

  void expectInvalid(Map<String, Object?> payload, String diagnostic) {
    final File log = logFile(
      'invalid.log',
      _completeRun(firstPayload: payload),
    );
    final (int code, String out, String err) = run(<String>['--log', log.path]);
    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(err, contains(diagnostic));
  }

  test('renders modes, actual sample counts and dropped-frame column', () {
    final File log = logFile('valid.log', _completeRun());
    final (int code, String out, String err) = run(<String>['--log', log.path]);

    expect(code, 0);
    expect(err, isEmpty);
    expect(out, contains('First Frame Samples'));
    expect(
      out,
      contains(
        '| fast_fling | platformView | 12.35 | 10 | 8 | 5 | 120 | 260 | 2 | 7 |',
      ),
    );
    expect(out, contains('| network_recovery | texture |'));
    expect(out, isNot(contains('maxDroppedFramesEstimate')));
  });

  test('ignores non-summary lines and malformed JSON payloads', () {
    final File log = logFile('mixed.log', <String>[
      'noise before',
      'NFP_BENCHMARK_SUMMARY {not json',
      'NFP_BENCHMARK_SUMMARY ',
      ..._completeRun(),
    ]);
    final (int code, String out, String err) = run(<String>['--log', log.path]);

    expect(code, 0);
    expect(err, isEmpty);
    expect(out, contains('| fast_fling | platformView |'));
    expect(out, contains('| pause_resume | texture |'));
  });

  for (final String field in <String>[
    'scenario',
    'renderMode',
    'durationMs',
    'metricSamples',
    'trackedControllers',
    'firstFrameSamples',
    'firstFrameP50Ms',
    'firstFrameP95Ms',
    'maxRebufferCount',
    'maxDroppedFrames',
  ]) {
    test('fails with a data error when $field is missing', () {
      expectInvalid(_validPayload()..remove(field), field);
    });
  }

  test('fails when a required value has the wrong type', () {
    // Encode manually so the value can be a non-numeric string.
    final String line = 'NFP_BENCHMARK_SUMMARY ${jsonEncode(_validPayload())}'
        .replaceFirst('"maxDroppedFrames":7', '"maxDroppedFrames":"many"');
    final File file = logFile('wrong-type.log', <String>[
      line,
      ..._completeRun().skip(1),
    ]);
    final (int code, String out, String err) = run(<String>[
      '--log',
      file.path,
    ]);

    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(err, contains('maxDroppedFrames'));
  });

  for (final String field in <String>[
    'durationMs',
    'metricSamples',
    'trackedControllers',
    'firstFrameSamples',
    'firstFrameP50Ms',
    'firstFrameP95Ms',
    'maxRebufferCount',
    'maxDroppedFrames',
  ]) {
    for (final Object? value in <Object?>[
      null,
      -1,
      0.5,
      '0',
      true,
      9007199254740992,
    ]) {
      test('rejects $field=$value', () {
        expectInvalid(<String, Object?>{
          ..._validPayload(),
          field: value,
        }, field);
      });
    }
    test('rejects nonfinite $field without an uncaught conversion error', () {
      final List<String> lines = _completeRun();
      lines[0] = lines[0].replaceFirst(
        RegExp('"$field":\\d+'),
        '"$field":1e400',
      );
      final File log = logFile('nonfinite.log', lines);
      final (int code, String out, String err) = run(<String>[
        '--log',
        log.path,
      ]);
      expect(code, benchmark_report.exitDataError);
      expect(out, isEmpty);
      expect(err, contains(field));
    });
  }

  test('accepts legitimate zero first-frame latency with rendered samples', () {
    final File log = logFile(
      'zero-latency.log',
      _completeRun(
        firstPayload: <String, Object?>{
          ..._validPayload(),
          'firstFrameP50Ms': 0,
          'firstFrameP95Ms': 0,
        },
      ),
    );
    final (int code, String out, String err) = run(<String>['--log', log.path]);
    expect(code, 0);
    expect(err, isEmpty);
    expect(out, contains('| 8 | 5 | 0 | 0 |'));
  });

  for (final Object? percentile in <Object?>[null, 0]) {
    test('rejects no rendered samples even with percentiles=$percentile', () {
      expectInvalid(<String, Object?>{
        ..._validPayload(),
        'firstFrameSamples': 0,
        'firstFrameP50Ms': percentile,
        'firstFrameP95Ms': percentile,
      }, 'firstFrameSamples');
    });
  }

  for (final Map<String, Object?> overrides in <Map<String, Object?>>[
    <String, Object?>{'durationMs': 0},
    <String, Object?>{'metricSamples': 0},
    <String, Object?>{'firstFrameSamples': 1},
    <String, Object?>{'firstFrameSamples': 9},
    <String, Object?>{'metricSamples': 4},
    <String, Object?>{'trackedControllers': 0},
  ]) {
    test('rejects insufficient or inflated samples: $overrides', () {
      expectInvalid(<String, Object?>{
        ..._validPayload(),
        ...overrides,
      }, 'rendered data');
    });
  }

  test('rejects reversed percentiles', () {
    expectInvalid(<String, Object?>{
      ..._validPayload(),
      'firstFrameP95Ms': 119,
    }, 'percentiles');
  });

  test('rejects unequal percentiles for a single first-frame sample', () {
    final List<String> lines = _completeRun();
    lines[2] = _summaryLine(<String, Object?>{
      ..._validPayload(scenario: 'pause_resume'),
      'firstFrameP95Ms': 121,
    });
    final File log = logFile('single-sample.log', lines);
    final (int code, String out, String err) = run(<String>['--log', log.path]);
    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(err, contains('percentiles'));
  });

  test('rejects duplicate scenario and render-mode summaries', () {
    final File log = logFile('duplicate.log', <String>[
      ..._completeRun(),
      _summaryLine(_validPayload()),
    ]);
    final (int code, String out, String err) = run(<String>['--log', log.path]);
    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(
      err,
      contains('Duplicate benchmark summary: fast_fling/platformView'),
    );
  });

  for (int index = 0; index < 6; index += 1) {
    test('rejects absent rendered data in required summary $index', () {
      final List<String> lines = _completeRun();
      lines[index] = lines[index].replaceFirst(
        RegExp(r'"firstFrameSamples":\d+'),
        '"firstFrameSamples":0',
      );
      final File log = logFile('missing-frames.log', lines);
      final (int code, String out, String err) = run(<String>[
        '--log',
        log.path,
      ]);
      expect(code, benchmark_report.exitDataError);
      expect(out, isEmpty);
      expect(err, contains('firstFrameSamples=0'));
    });
  }

  test('requires all scenarios in both render modes', () {
    final File log = logFile('incomplete.log', _completeRun()..removeLast());
    final (int code, String out, String err) = run(<String>['--log', log.path]);
    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(
      err,
      contains('Missing required benchmarks: network_recovery/texture'),
    );
  });

  test('rejects unknown scenarios and rendering modes', () {
    expectInvalid(<String, Object?>{
      ..._validPayload(),
      'scenario': 'scroll',
    }, 'Unknown scenario');
    expectInvalid(<String, Object?>{
      ..._validPayload(),
      'renderMode': 'unknown',
    }, 'Unknown scenario/renderMode');
  });

  test('exits with the no-data code when the log has no summaries', () {
    final File file = logFile('empty.log', <String>['unrelated output']);
    final (int code, String out, String err) = run(<String>[
      '--log',
      file.path,
    ]);
    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(err, contains('No benchmark summary lines found'));
  });

  test('does not overwrite an existing report on invalid data', () {
    final File log = logFile('incomplete.log', _completeRun()..removeLast());
    final File report = File('${tempDir.path}/report.md')
      ..writeAsStringSync('previous report');
    final (int code, String out, String err) = run(<String>[
      '--log',
      log.path,
      '--out',
      report.path,
    ]);
    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(err, isNotEmpty);
    expect(report.readAsStringSync(), 'previous report');
  });

  test('writes the report to --out and reports the destination', () {
    final File log = logFile('valid.log', _completeRun());
    final String outPath = '${tempDir.path}/nested/report.md';
    final (int code, String out, String err) = run(<String>[
      '--log',
      log.path,
      '--out',
      outPath,
    ]);

    expect(code, 0);
    expect(err, isEmpty);
    expect(out, contains('Wrote benchmark report'));
    expect(File(outPath).readAsStringSync(), contains('| 7 |'));
  });
}
