import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sito/src/static_handler.dart';
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late String rootPath;
  late HttpServer server;
  late HttpClient client;

  void writeFile(String relativePath, String contents) {
    File(p.join(rootPath, relativePath))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  Future<({int status, HttpHeaders headers, String body})> send(
    String path, {
    String method = 'GET',
    Map<String, String> headers = const {},
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (status: response.statusCode, headers: response.headers, body: body);
  }

  /// Sends [requestTarget] verbatim, because [HttpClient] normalizes `..`.
  Future<String> sendRawStatusLine(String requestTarget) async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.write('GET $requestTarget HTTP/1.1\r\nHost: localhost\r\n\r\n');
    await socket.flush();
    final statusLine = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first;
    socket.destroy();
    return statusLine;
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('sito_static_');
    final resolvedSandboxPath = await sandbox.resolveSymbolicLinks();
    rootPath = p.join(resolvedSandboxPath, 'root');
    Directory(rootPath).createSync();
    File(p.join(resolvedSandboxPath, 'secret.txt')).writeAsStringSync('secret');

    writeFile('index.html', '<h1>home</h1>');
    writeFile('about.html', '<h1>about</h1>');
    writeFile('docs/index.html', '<h1>docs</h1>');
    writeFile('empty/file.txt', 'not an index');
    writeFile('styles/main.css', 'body {}');
    writeFile('scripts/app.js', 'run()');
    writeFile('images/logo.svg', '<svg/>');
    writeFile('my file ñ.txt', 'spaced');
    writeFile('data.unknownextension', 'bytes');
    writeFile('digits.txt', '0123456789');
    writeFile('.env', 'SECRET=1');
    writeFile('.git/config', 'secret');
    writeFile('.well-known/security.txt', 'contact');

    final handler = StaticHandler(rootPath);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler.handleRequest);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    await sandbox.delete(recursive: true);
  });

  group('file resolution', () {
    test('serves an existing HTML file', () async {
      final result = await send('/about.html');
      expect(result.status, 200);
      expect(result.body, '<h1>about</h1>');
    });

    test('resolves / to index.html', () async {
      expect((await send('/')).body, '<h1>home</h1>');
    });

    test('resolves nested directory indexes', () async {
      expect((await send('/docs/')).body, '<h1>docs</h1>');
    });

    test('redirects a directory without a trailing slash', () async {
      final result = await send('/docs?version=2');
      expect(result.status, 302);
      expect(result.headers.value('location'), '/docs/?version=2');
    });

    test('returns 404 for nonexistent files', () async {
      expect((await send('/missing.html')).status, 404);
    });

    test('returns 404 for directories without an index', () async {
      expect((await send('/empty/')).status, 404);
    });

    test('handles URL-encoded spaces and Unicode', () async {
      final result = await send('/my%20file%20%C3%B1.txt');
      expect(result.status, 200);
      expect(result.body, 'spaced');
    });
  });

  group('media types', () {
    for (final (path, expectedContentType) in const [
      ('/about.html', 'text/html; charset=utf-8'),
      ('/styles/main.css', 'text/css; charset=utf-8'),
      ('/scripts/app.js', 'text/javascript; charset=utf-8'),
      ('/images/logo.svg', 'image/svg+xml'),
      ('/data.unknownextension', 'application/octet-stream'),
    ]) {
      test('serves $path as $expectedContentType', () async {
        final result = await send(path);
        expect(result.status, 200);
        expect(
          result.headers.value(HttpHeaders.contentTypeHeader),
          expectedContentType,
        );
      });
    }
  });

  group('http behavior', () {
    test('HEAD returns headers without a body', () async {
      final result = await send('/about.html', method: 'HEAD');
      expect(result.status, 200);
      expect(result.body, isEmpty);
      expect(result.headers.contentLength, '<h1>about</h1>'.length);
      expect(
        result.headers.value(HttpHeaders.contentTypeHeader),
        'text/html; charset=utf-8',
      );
    });

    test('returns 405 with Allow for other methods', () async {
      final result = await send('/about.html', method: 'POST');
      expect(result.status, 405);
      expect(result.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
    });

    test('disables browser caching', () async {
      final result = await send('/about.html');
      expect(result.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    });
  });

  group('range requests', () {
    Future<void> expectRange(
      String rangeHeader,
      int expectedStatus,
      String expectedBody, [
      String? expectedContentRange,
    ]) async {
      final result = await send(
        '/digits.txt',
        headers: {HttpHeaders.rangeHeader: rangeHeader},
      );
      expect(result.status, expectedStatus);
      expect(result.body, expectedBody);
      expect(
        result.headers.value(HttpHeaders.contentRangeHeader),
        expectedContentRange,
      );
    }

    test(
      'closed range',
      () => expectRange('bytes=2-4', 206, '234', 'bytes 2-4/10'),
    );
    test(
      'open range',
      () => expectRange('bytes=7-', 206, '789', 'bytes 7-9/10'),
    );
    test(
      'suffix range',
      () => expectRange('bytes=-2', 206, '89', 'bytes 8-9/10'),
    );
    test(
      'end past the file is clamped',
      () => expectRange('bytes=8-99', 206, '89', 'bytes 8-9/10'),
    );
    test(
      'start past the file is 416',
      () => expectRange('bytes=10-', 416, '', 'bytes */10'),
    );
    test(
      'multi-range falls back to the whole file',
      () => expectRange('bytes=0-1,3-4', 200, '0123456789'),
    );
    test(
      'malformed range falls back to the whole file',
      () => expectRange('bytes=4-2', 200, '0123456789'),
    );
    test(
      'overflowing range falls back to the whole file',
      () => expectRange('bytes=0-99999999999999999999', 200, '0123456789'),
    );
  });

  group('security', () {
    test('rejects directory traversal', () async {
      expect(await sendRawStatusLine('/../secret.txt'), contains('404'));
    });

    test('rejects encoded directory traversal', () async {
      for (final target in const [
        '/%2e%2e/secret.txt',
        '/%2E%2E%2Fsecret.txt',
        '/docs/..%2F..%2Fsecret.txt',
        '/..%5Csecret.txt',
      ]) {
        expect(
          await sendRawStatusLine(target),
          contains('404'),
          reason: target,
        );
      }
    });

    test('rejects a NUL byte', () async {
      expect(await sendRawStatusLine('/index.html%00.txt'), contains('404'));
    });

    test('answers malformed percent-encoding without crashing', () async {
      expect(await sendRawStatusLine('/%zz'), contains('404'));
      expect((await send('/about.html')).status, 200);
    });

    test('does not serve a symlink pointing outside the root', () async {
      Link(p.join(rootPath, 'escape.txt'))
          .createSync(p.join(p.dirname(rootPath), 'secret.txt'));
      expect((await send('/escape.txt')).status, 404);
    });

    test(
      'does not serve through a directory symlink outside the root',
      () async {
        Link(p.join(rootPath, 'escape')).createSync(p.dirname(rootPath));
        expect((await send('/escape/secret.txt')).status, 404);
      },
    );

    test('serves a symlink that stays inside the root', () async {
      Link(p.join(rootPath, 'alias.html'))
          .createSync(p.join(rootPath, 'about.html'));
      expect((await send('/alias.html')).body, '<h1>about</h1>');
    });

    test('does not serve a symlink pointing at a hidden file', () async {
      Link(p.join(rootPath, 'visible.txt'))
          .createSync(p.join(rootPath, '.env'));
      expect((await send('/visible.txt')).status, 404);
    });

    test('hides dotfiles and dot directories', () async {
      expect((await send('/.env')).status, 404);
      expect((await send('/.git/config')).status, 404);
    });

    test('serves .well-known', () async {
      expect((await send('/.well-known/security.txt')).body, 'contact');
    });
  });
}
