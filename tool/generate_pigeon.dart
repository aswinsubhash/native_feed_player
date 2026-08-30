import 'dart:io';

Future<void> main() async {
  final Directory root = File.fromUri(Platform.script).parent.parent;
  final String dart = Platform.resolvedExecutable;
  final List<String> generated = <String>[
    'lib/src/messages.g.dart',
    'android/src/main/kotlin/io/github/aswinsubhash/native_feed_player/Messages.g.kt',
    'ios/native_feed_player/Sources/native_feed_player/Messages.g.swift',
  ];
  final ProcessResult generation = await Process.run(dart, <String>[
    'run',
    'pigeon',
    '--input',
    'pigeons/native_feed_player_messages.dart',
    '--dart_out',
    generated[0],
    '--kotlin_out',
    generated[1],
    '--kotlin_package',
    'io.github.aswinsubhash.native_feed_player',
    '--swift_out',
    generated[2],
  ], workingDirectory: root.path);
  stdout.write(generation.stdout);
  stderr.write(generation.stderr);
  if (generation.exitCode != 0) {
    exitCode = generation.exitCode;
    return;
  }

  for (final String path in generated.skip(1)) {
    final File file = File('${root.path}/$path');
    final List<String> lines = (await file.readAsLines())
        .map((String line) => line.replaceFirst(RegExp(r'\s+$'), ''))
        .toList();
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    await file.writeAsString('${lines.join('\n')}\n');
  }

  final ProcessResult formatting = await Process.run(dart, <String>[
    'format',
    generated[0],
  ], workingDirectory: root.path);
  stdout.write(formatting.stdout);
  stderr.write(formatting.stderr);
  exitCode = formatting.exitCode;
}
