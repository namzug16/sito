import 'dart:convert';
import 'dart:io';

import 'package:sito/sito.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late SitoServer server;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sito_server_');
    File('${root.path}/index.html').writeAsStringSync('home');
    server = await SitoServer.start(
      resolvedRootPath: await root.resolveSymbolicLinks(),
      port: 0,
    );
  });

  tearDown(() async {
    await server.close();
    await root.delete(recursive: true);
  });

  Future<String> statusForHostHeader(String hostHeader) async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.write('GET / HTTP/1.1\r\nHost: $hostHeader\r\n\r\n');
    await socket.flush();
    final statusLine = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first;
    socket.destroy();
    return statusLine;
  }

  test('uses the loopback interface by default', () {
    expect(server.address.isLoopback, isTrue);
  });

  test('accepts loopback host names', () async {
    for (final host in [
      'localhost:${server.port}',
      'LOCALHOST',
      '127.0.0.1:${server.port}',
      '[::1]:${server.port}',
    ]) {
      expect(await statusForHostHeader(host), contains('200'), reason: host);
    }
  });

  test('rejects foreign host names to block DNS rebinding', () async {
    expect(await statusForHostHeader('evil.example'), contains('403'));
  });
}
