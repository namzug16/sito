import 'dart:io';

import 'package:sito/sito.dart';

Future<void> main(List<String> arguments) async {
  final cliExitCode = await runCli(arguments);
  await Future.wait([stdout.flush(), stderr.flush()]);
  // Signal watchers would otherwise keep the process alive.
  exit(cliExitCode);
}
