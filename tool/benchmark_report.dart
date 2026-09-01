import 'dart:convert';
import 'dart:io';

/// Exit code for malformed benchmark summary payloads.
const int exitDataError = 65;

/// Runs the report generator and returns the process exit code plus any
/// stdout/stderr text, so tests can exercise the CLI contract in-process.
(int, String, String) runBenchmarkReport(List<String> args) {
  final StringBuffer outBuffer = StringBuffer();
  final StringBuffer errBuffer = StringBuffer();
  final int code = _run(
    args: args,
    stdoutSink: outBuffer,
    stderrSink: errBuffer,
  );
  return (code, outBuffer.toString(), errBuffer.toString());
}

void main(List<String> args) {
  exitCode = _run(args: args, stdoutSink: stdout, stderrSink: stderr);
}

int _run({
  required List<String> args,
  required StringSink stdoutSink,
  required StringSink stderrSink,
}) {
  final Map<String, String> options = <String, String>{};
  bool append = false;

  for (int index = 0; index < args.length; index += 1) {
    final String arg = args[index];
    if (arg == '--append') {
      append = true;
      continue;
    }
    if (arg == '--help' || arg == '-h') {
      _printUsage(stdoutSink);
      return 0;
    }
    if (!arg.startsWith('--')) {
      stderrSink.writeln('Unknown argument: $arg');
      _printUsage(stderrSink);
      return 64;
    }

    final List<String> parts = arg.split('=');
    if (parts.length == 2) {
      options[parts[0].substring(2)] = parts[1];
      continue;
    }

    final String key = arg.substring(2);
    if (index + 1 >= args.length) {
      stderrSink.writeln('Missing value for --$key');
      _printUsage(stderrSink);
      return 64;
    }
    options[key] = args[index + 1];
    index += 1;
  }

  final String? logPath = options['log'];
  if (logPath == null || logPath.isEmpty) {
    stderrSink.writeln('Missing required argument: --log <path>');
    _printUsage(stderrSink);
    return 64;
  }

  final File logFile = File(logPath);
  if (!logFile.existsSync()) {
    stderrSink.writeln('Log file not found: $logPath');
    return 66;
  }

  final List<Map<String, dynamic>> summaries = _extractSummaries(logFile);
  if (summaries.isEmpty) {
    stderrSink.writeln(
      'No benchmark summary lines found. Expected lines prefixed with '
      '`NFP_BENCHMARK_SUMMARY `.',
    );
    return exitDataError;
  }

  final String report;
  try {
    report = _buildReport(
      summaries: summaries,
      logPath: logPath,
      device: options['device'] ?? 'unknown',
      osVersion: options['os'] ?? 'unknown',
      buildVariant: options['variant'] ?? '',
    );
  } on FormatException catch (error) {
    stderrSink.writeln('Malformed benchmark summary: ${error.message}');
    return exitDataError;
  }

  final String? outPath = options['out'];
  if (outPath == null || outPath.isEmpty) {
    stdoutSink.write(report);
    return 0;
  }

  final File outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    report,
    mode: append ? FileMode.append : FileMode.write,
  );
  stdoutSink.writeln('Wrote benchmark report: $outPath');
  return 0;
}

List<Map<String, dynamic>> _extractSummaries(File logFile) {
  const String prefix = 'NFP_BENCHMARK_SUMMARY ';
  final List<Map<String, dynamic>> summaries = <Map<String, dynamic>>[];

  for (final String line in logFile.readAsLinesSync()) {
    final int index = line.indexOf(prefix);
    if (index < 0) {
      continue;
    }
    final String jsonPayload = line.substring(index + prefix.length).trim();
    if (jsonPayload.isEmpty) {
      continue;
    }
    try {
      final Object? decoded = jsonDecode(jsonPayload);
      if (decoded is Map<String, dynamic>) {
        summaries.add(decoded);
      }
    } catch (_) {
      // Ignore malformed lines and continue parsing.
    }
  }

  return summaries;
}

String _buildReport({
  required List<Map<String, dynamic>> summaries,
  required String logPath,
  required String device,
  required String osVersion,
  required String buildVariant,
}) {
  final StringBuffer buffer = StringBuffer();
  final String generatedAt = DateTime.now().toUtc().toIso8601String();

  buffer.writeln('## Device Benchmark');
  buffer.writeln();
  buffer.writeln('- Device: `$device`');
  buffer.writeln('- OS: `$osVersion`');
  if (buildVariant.isNotEmpty) {
    buffer.writeln('- Variant: `$buildVariant`');
  }
  buffer.writeln('- Source log: `$logPath`');
  buffer.writeln('- Generated at (UTC): `$generatedAt`');
  buffer.writeln();
  buffer.writeln(
    '| Scenario | Duration (s) | Metric Samples | First Frame P50 (ms) | '
    'First Frame P95 (ms) | Max Rebuffer | Max Dropped Frames |',
  );
  buffer.writeln('| --- | ---: | ---: | ---: | ---: | ---: | ---: |');

  for (final Map<String, dynamic> summary in summaries) {
    final String scenario = _stringValue(
      summary,
      'scenario',
      fallback: 'unknown',
    );
    final int durationMs = _intValue(summary, 'durationMs');
    final int metricSamples = _intValue(summary, 'metricSamples');
    final int p50 = _intValue(summary, 'firstFrameP50Ms');
    final int p95 = _intValue(summary, 'firstFrameP95Ms');
    final int maxRebuffer = _intValue(summary, 'maxRebufferCount');
    final int maxDropped = _intValue(summary, 'maxDroppedFrames');
    final String durationSec = (durationMs / 1000).toStringAsFixed(2);
    buffer.writeln(
      '| $scenario | $durationSec | $metricSamples | $p50 | $p95 | '
      '$maxRebuffer | $maxDropped |',
    );
  }

  buffer.writeln();
  return buffer.toString();
}

int _intValue(Map<String, dynamic> source, String key) {
  final Object? value = source[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  throw FormatException(
    'Benchmark summary is missing a numeric "$key" field '
    '(got ${value == null ? 'nothing' : value.runtimeType}).',
  );
}

String _stringValue(
  Map<String, dynamic> source,
  String key, {
  required String fallback,
}) {
  final Object? value = source[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return fallback;
}

void _printUsage(StringSink sink) {
  sink.writeln('Usage:');
  sink.writeln(
    '  dart run tool/benchmark_report.dart '
    '--log <log_file> [--device <name>] [--os <version>] '
    '[--variant <build>] [--out <report.md>] [--append]',
  );
}
