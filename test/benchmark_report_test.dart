import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../tool/benchmark_report.dart' as benchmark_report;

String _summaryLine(Map<String, Object?> payload) =>
    'NFP_BENCHMARK_SUMMARY ${jsonEncode(payload)}';

Map<String, Object?> _validPayload({String scenario = 'scroll'}) =>
    <String, Object?>{
      'scenario': scenario,
      'durationMs': 12345,
      'metricSamples': 10,
      'firstFrameSamples': 5,
      'firstFrameP50Ms': 120,
      'firstFrameP95Ms': 260,
      'maxRebufferCount': 2,
      'maxDroppedFrames': 7,
      'timestampMs': 1700000000000,
    };

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

  test('renders the dropped-frame column from maxDroppedFrames', () {
    final File log = logFile('valid.log', <String>[
      _summaryLine(_validPayload()),
    ]);

    final (int code, String out, String err) = run(<String>['--log', log.path]);

    expect(code, 0);
    expect(err, isEmpty);
    expect(out, contains('| 7 |'));
    expect(out, isNot(contains('maxDroppedFramesEstimate')));
  });

  test('ignores non-summary lines and malformed JSON payloads', () {
    final File log = logFile('mixed.log', <String>[
      'noise before',
      _summaryLine(<String, Object?>{..._validPayload(), 'scenario': 'a'}),
      'NFP_BENCHMARK_SUMMARY {not json',
      'NFP_BENCHMARK_SUMMARY ',
      _summaryLine(_validPayload(scenario: 'b')),
    ]);

    final (int code, String out, String err) = run(<String>['--log', log.path]);

    expect(code, 0);
    expect(out, contains('| a |'));
    expect(out, contains('| b |'));
  });

  test('fails with a data error when a required key is missing', () {
    final Map<String, Object?> payload = _validPayload()
      ..remove('maxDroppedFrames');
    final File log = logFile('missing.log', <String>[_summaryLine(payload)]);

    final (int code, String out, String err) = run(<String>['--log', log.path]);

    expect(code, benchmark_report.exitDataError);
    expect(out, isEmpty);
    expect(err, contains('maxDroppedFrames'));
  });

  test('fails when a required value has the wrong type', () {
    // Encode manually so the value can be a non-numeric string.
    final String line = 'NFP_BENCHMARK_SUMMARY ${jsonEncode(_validPayload())}'
        .replaceFirst('"maxDroppedFrames":7', '"maxDroppedFrames":"many"');
    final File file = logFile('wrong-type.log', <String>[line]);

    final (int code, String out, String err) = run(<String>[
      '--log',
      file.path,
    ]);

    expect(code, benchmark_report.exitDataError);
    expect(err, contains('maxDroppedFrames'));
  });

  test('exits with the no-data code when the log has no summaries', () {
    final File file = logFile('empty.log', <String>['unrelated output']);

    final (int code, String out, String err) = run(<String>[
      '--log',
      file.path,
    ]);

    expect(code, benchmark_report.exitDataError);
    expect(err, contains('No benchmark summary lines found'));
  });

  test('writes the report to --out and reports the destination', () {
    final File log = logFile('valid.log', <String>[
      _summaryLine(_validPayload()),
    ]);
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
