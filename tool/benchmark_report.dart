import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final Map<String, String> options = <String, String>{};
  bool append = false;

  for (int index = 0; index < args.length; index += 1) {
    final String arg = args[index];
    if (arg == '--append') {
      append = true;
      continue;
    }
    if (arg == '--help' || arg == '-h') {
      _printUsage();
      return;
    }
    if (!arg.startsWith('--')) {
      stderr.writeln('Unknown argument: $arg');
      _printUsage();
      exitCode = 64;
      return;
    }

    final List<String> parts = arg.split('=');
    if (parts.length == 2) {
      options[parts[0].substring(2)] = parts[1];
      continue;
    }

    final String key = arg.substring(2);
    if (index + 1 >= args.length) {
      stderr.writeln('Missing value for --$key');
      _printUsage();
      exitCode = 64;
      return;
    }
    options[key] = args[index + 1];
    index += 1;
  }

  final String? logPath = options['log'];
  if (logPath == null || logPath.isEmpty) {
    stderr.writeln('Missing required argument: --log <path>');
    _printUsage();
    exitCode = 64;
    return;
  }

  final File logFile = File(logPath);
  if (!logFile.existsSync()) {
    stderr.writeln('Log file not found: $logPath');
    exitCode = 66;
    return;
  }

  final List<Map<String, dynamic>> summaries = _extractSummaries(logFile);
  if (summaries.isEmpty) {
    stderr.writeln(
      'No benchmark summary lines found. Expected lines prefixed with '
      '`NFP_BENCHMARK_SUMMARY `.',
    );
    exitCode = 65;
    return;
  }

  final String report = _buildReport(
    summaries: summaries,
    logPath: logPath,
    device: options['device'] ?? 'unknown',
    osVersion: options['os'] ?? 'unknown',
    buildVariant: options['variant'] ?? '',
  );

  final String? outPath = options['out'];
  if (outPath == null || outPath.isEmpty) {
    stdout.write(report);
    return;
  }

  final File outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    report,
    mode: append ? FileMode.append : FileMode.write,
  );
  stdout.writeln('Wrote benchmark report: $outPath');
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
    final int maxDropped = _intValue(summary, 'maxDroppedFramesEstimate');
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
  return 0;
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

void _printUsage() {
  stdout.writeln('Usage:');
  stdout.writeln(
    '  dart run tool/benchmark_report.dart '
    '--log <log_file> [--device <name>] [--os <version>] '
    '[--variant <build>] [--out <report.md>] [--append]',
  );
}
