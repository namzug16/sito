import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sito/sito.dart';
import 'package:test/test.dart';

final sitoScriptPath = p.absolute('bin/sito.dart');

void main() {
  late Directory sandbox;
  late String rootPath;
  final startedProcesses = <Process>[];

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('sito_cli_');
    rootPath = await sandbox.resolveSymbolicLinks();
    File(p.join(rootPath, 'index.html')).writeAsStringSync('<h1>home</h1>');
  });

  tearDown(() async {
    for (final process in startedProcesses) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    startedProcesses.clear();
    await sandbox.delete(recursive: true);
  });

  Future<ProcessResult> runSito(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    [sitoScriptPath, ...arguments],
    workingDirectory: rootPath,
  );

  Future<int> findFreePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  /// Starts sito and waits for its banner to finish printing.
  Future<({Process process, String banner, List<String> errorLines})> startSito(
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [sitoScriptPath, ...arguments],
      workingDirectory: rootPath,
      environment: environment,
    );
    startedProcesses.add(process);
    final errorLines = <String>[];
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(errorLines.add);
    final bannerLines = <String>[];
    await for (final line
        in process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      bannerLines.add(line);
      if (line.contains('Press Ctrl+C')) break;
    }
    return (
      process: process,
      banner: bannerLines.join('\n'),
      errorLines: errorLines,
    );
  }

  Future<String> fetch(int port) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('http://localhost:$port/'));
      return await utf8.decoder.bind(await request.close()).join();
    } finally {
      client.close();
    }
  }

  test('displays help', () async {
    final result = await runSito(['--help']);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('--port'));
    expect(result.stdout, contains('Usage: sito'));
  });

  test('displays the version', () async {
    final result = await runSito(['--version']);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('sito v$sitoVersion'));
  });

  test('the version matches pubspec.yaml', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: $sitoVersion'),
    );
  });

  test('rejects a missing directory', () async {
    final result = await runSito(['./public']);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('Directory "./public" does not exist.'));
    expect(result.stderr, isNot(contains('#0')));
  });

  test('rejects a file as the root', () async {
    final result = await runSito(['index.html']);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('is not a directory'));
  });

  test('rejects more than one directory', () async {
    expect((await runSito(['a', 'b'])).exitCode, 64);
  });

  test('rejects invalid ports', () async {
    for (final port in const ['0', '65536', 'abc']) {
      expect((await runSito(['-p', port])).exitCode, 64, reason: port);
    }
  });

  test('rejects unknown flags', () async {
    expect((await runSito(['--nope'])).exitCode, 64);
  });

  test('reports an unavailable port', () async {
    final occupier = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(occupier.close);
    final result = await runSito(['-p', '${occupier.port}']);
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains('Error: Port ${occupier.port} is already in use.'),
    );
    expect(result.stderr, contains('Try: sito -p ${occupier.port + 1}'));
  });

  test('serves the current directory by default on a custom port', () async {
    final port = await findFreePort();
    final started = await startSito(['-p', '$port']);
    expect(started.banner, contains('Local:    http://localhost:$port'));
    expect(started.banner, contains('Network:  disabled'));
    expect(started.banner, contains('Root:     $rootPath'));
    expect(await fetch(port), '<h1>home</h1>');
  });

  test('serves a custom directory', () async {
    Directory(p.join(rootPath, 'public')).createSync();
    File(p.join(rootPath, 'public', 'index.html')).writeAsStringSync('public');
    final port = await findFreePort();
    await startSito(['./public', '-p', '$port']);
    expect(await fetch(port), 'public');
  });

  test('warns about a __sito directory under --reload', () async {
    Directory(p.join(rootPath, '__sito')).createSync();
    final port = await findFreePort();
    final started = await startSito(['-p', '$port', '--reload']);
    expect(started.banner, contains('Reload:   enabled'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(started.errorLines.join(), contains('__sito'));
  });

  test('keeps serving when the browser cannot be opened', () async {
    final port = await findFreePort();
    final started = await startSito(
      ['-p', '$port', '--open'],
      environment: {'PATH': ''},
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(started.errorLines.join(), contains('Could not open the browser'));
    expect(await fetch(port), '<h1>home</h1>');
  });

  test('warns when reachable from the network', () async {
    final port = await findFreePort();
    final started = await startSito(['-p', '$port', '--host', '0.0.0.0']);
    expect(started.banner, contains('reachable from other devices'));
    expect(started.banner, isNot(contains('Network:  disabled')));
    expect(started.banner, isNot(contains('http://[')));
  });

  test('shuts down cleanly on termination', () async {
    final port = await findFreePort();
    final started = await startSito(['-p', '$port']);
    started.process.kill(ProcessSignal.sigterm);
    expect(await started.process.exitCode, 0);
  }, skip: Platform.isWindows ? 'Windows has no SIGTERM' : false);
}
