import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'reload.dart';
import 'server.dart';

const sitoVersion = '0.1.0';

const _usageExitCode = 64;
const _runtimeFailureExitCode = 1;

const _portInUseErrorCodes = {48, 98, 10048};
const _permissionDeniedErrorCodes = {13, 10013};

/// Runs the command line and returns the process exit code once the server
/// has stopped.
Future<int> runCli(List<String> arguments) async {
  final argumentParser = _buildArgumentParser();
  try {
    final parsedArguments = argumentParser.parse(arguments);
    if (parsedArguments.flag('help')) {
      print('Usage: sito [directory] [options]\n');
      print(argumentParser.usage);
      return 0;
    }
    if (parsedArguments.flag('version')) {
      print('sito v$sitoVersion');
      return 0;
    }
    return await _serve(parsedArguments);
  } on _UsageFailure catch (failure) {
    stderr.writeln('Error: ${failure.message}');
    return _usageExitCode;
  } on FormatException catch (failure) {
    stderr.writeln('Error: ${failure.message}');
    return _usageExitCode;
  } on FileSystemException catch (failure) {
    stderr.writeln('Error: Could not read "${failure.path}".');
    return _runtimeFailureExitCode;
  }
}

ArgParser _buildArgumentParser() {
  return ArgParser()
    ..addOption(
      'port',
      abbr: 'p',
      defaultsTo: '3000',
      help: 'Port to listen on.',
    )
    ..addOption(
      'host',
      defaultsTo: '127.0.0.1',
      help: 'Interface to bind to. Use 0.0.0.0 to allow other devices.',
    )
    ..addFlag(
      'reload',
      negatable: false,
      help: 'Reload the browser when files change.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag('version', negatable: false, help: 'Print the tool version.');
}

Future<int> _serve(ArgResults parsedArguments) async {
  final port = _parsePort(parsedArguments.option('port')!);
  final host = parsedArguments.option('host')!;
  final resolvedRootPath = await _resolveRootDirectory(parsedArguments.rest);
  final liveReloadEnabled = parsedArguments.flag('reload');

  final SitoServer server;
  try {
    server = await SitoServer.start(
      resolvedRootPath: resolvedRootPath,
      port: port,
      host: host,
      liveReloadEnabled: liveReloadEnabled,
    );
  } on SocketException catch (failure) {
    stderr.writeln(_describeBindFailure(failure, host, port));
    return _runtimeFailureExitCode;
  }

  // Watch before printing so a signal right after the banner stops cleanly.
  final terminationRequested = _waitForTerminationSignal();
  await _printBanner(server, host, resolvedRootPath, liveReloadEnabled);
  if (liveReloadEnabled &&
      Directory(p.join(resolvedRootPath, '__sito')).existsSync()) {
    stderr.writeln(
      'Warning: Live reload reserves $reloadEndpointPath, which takes '
      'priority over your __sito directory.',
    );
  }

  await terminationRequested;
  await server.close();
  return 0;
}

int _parsePort(String portText) {
  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) {
    throw _UsageFailure('Port must be between 1 and 65535, got "$portText".');
  }
  return port;
}

Future<String> _resolveRootDirectory(List<String> positionalArguments) async {
  if (positionalArguments.length > 1) {
    throw _UsageFailure(
      'Expected one directory, got ${positionalArguments.length}.',
    );
  }
  final directoryPath = positionalArguments.firstOrNull ?? '.';
  final entityType = await FileSystemEntity.type(directoryPath);
  if (entityType == FileSystemEntityType.notFound) {
    throw _UsageFailure('Directory "$directoryPath" does not exist.');
  }
  if (entityType != FileSystemEntityType.directory) {
    throw _UsageFailure('"$directoryPath" is not a directory.');
  }
  return Directory(directoryPath).resolveSymbolicLinks();
}

String _describeBindFailure(SocketException failure, String host, int port) {
  final errorCode = failure.osError?.errorCode;
  if (_portInUseErrorCodes.contains(errorCode)) {
    final alternativePort = port == 65535 ? port - 1 : port + 1;
    return 'Error: Port $port is already in use.\n'
        'Try: sito -p $alternativePort';
  }
  if (_permissionDeniedErrorCodes.contains(errorCode)) {
    return 'Error: Permission denied for port $port.\nTry: sito -p 3000';
  }
  return 'Error: Could not listen on $host:$port.';
}

Future<void> _printBanner(
  SitoServer server,
  String host,
  String resolvedRootPath,
  bool liveReloadEnabled,
) async {
  print('sito v$sitoVersion\n');
  print('  Local:    ${_browserUrl(server, host)}');
  final networkUrls = await _networkUrls(server, host);
  if (networkUrls.isEmpty) {
    print('  Network:  disabled');
  }
  for (final networkUrl in networkUrls) {
    print('  Network:  $networkUrl');
  }
  print('  Root:     $resolvedRootPath');
  print('  Reload:   ${liveReloadEnabled ? 'enabled' : 'disabled'}');
  if (networkUrls.isNotEmpty) {
    print('\n  Warning: reachable from other devices on your network.');
  }
  print('\n  Press Ctrl+C to stop');
}

bool _isBoundToAllInterfaces(SitoServer server) =>
    server.address.rawAddress.every((addressByte) => addressByte == 0);

String _browserUrl(SitoServer server, String host) {
  final displayedHost =
      server.address.isLoopback || _isBoundToAllInterfaces(server)
      ? 'localhost'
      : host;
  return Uri(scheme: 'http', host: displayedHost, port: server.port).toString();
}

Future<List<String>> _networkUrls(SitoServer server, String host) async {
  if (server.address.isLoopback) return const [];
  if (!_isBoundToAllInterfaces(server)) {
    return [Uri(scheme: 'http', host: host, port: server.port).toString()];
  }
  final networkInterfaces = await NetworkInterface.list();
  return [
    for (final networkInterface in networkInterfaces)
      for (final interfaceAddress in networkInterface.addresses)
        Uri(
          scheme: 'http',
          host: interfaceAddress.address,
          port: server.port,
        ).toString(),
  ];
}

Future<void> _waitForTerminationSignal() {
  return Future.any([
    ProcessSignal.sigint.watch().first,
    // Windows cannot watch SIGTERM.
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().first,
  ]);
}

class _UsageFailure implements Exception {
  _UsageFailure(this.message);

  final String message;
}
