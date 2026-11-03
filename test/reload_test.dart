import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sito/sito.dart';
import 'package:sito/src/reload.dart';
import 'package:test/test.dart';

/// Long enough for a watcher to deliver a change that is going to arrive.
const _settleDuration = Duration(milliseconds: 800);

void main() {
  group('injectReloadScript', () {
    String inject(String html) =>
        latin1.decode(injectReloadScript(latin1.encode(html)));

    test('inserts before the last closing body tag', () {
      final result = inject('<body>a</body>b</BODY>');
      expect(result, startsWith('<body>a</body>b<script>'));
      expect(result, endsWith('</script></BODY>'));
    });

    test('appends when there is no closing body tag', () {
      final result = inject('<h1>fragment</h1>');
      expect(result, startsWith('<h1>fragment</h1><script>'));
      expect(result, endsWith('</script>'));
    });

    test('leaves non-UTF-8 bytes untouched', () {
      final result = injectReloadScript([0xE9, ...ascii.encode('</body>')]);
      expect(result.first, 0xE9);
    });

    test('reconnects after the socket closes', () {
      expect(inject(''), contains('socket.onclose'));
      expect(inject(''), contains('setTimeout(connect'));
    });
  });

  group('isRelevantChange', () {
    test('accepts project files', () {
      expect(isRelevantChange('index.html'), isTrue);
      expect(isRelevantChange(p.join('styles', 'main.css')), isTrue);
    });

    test('ignores temporary files and hidden or dependency paths', () {
      for (final relativePath in [
        'index.html~',
        '.index.html.swp',
        'index.html.swx',
        'upload.tmp',
        '4913',
        p.join('.git', 'index'),
        p.join('node_modules', 'pkg', 'index.js'),
      ]) {
        expect(isRelevantChange(relativePath), isFalse, reason: relativePath);
      }
    });
  });

  // Exercises the per-directory strategy that Linux uses, on every platform.
  for (final watchEachDirectory in [false, true]) {
    group('LiveReload with watchEachDirectory=$watchEachDirectory', () {
      late Directory sandbox;
      late String rootPath;
      late LiveReload liveReload;
      late HttpServer httpServer;
      late WebSocket browser;
      late List<Object?> reloadMessages;

      Future<void> connectBrowser() async {
        browser = await WebSocket.connect('ws://127.0.0.1:${httpServer.port}');
        browser.listen(reloadMessages.add);
      }

      setUp(() async {
        sandbox = await Directory.systemTemp.createTemp('sito_reload_');
        rootPath = await sandbox.resolveSymbolicLinks();
        File(p.join(rootPath, 'index.html')).writeAsStringSync('home');
        Directory(p.join(rootPath, 'nested', 'deep'))
            .createSync(recursive: true);
        Directory(p.join(rootPath, '.git')).createSync();

        reloadMessages = [];
        liveReload = LiveReload(
          rootPath,
          watchEachDirectory: watchEachDirectory,
        );
        await liveReload.start();
        httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        httpServer.listen(liveReload.acceptBrowser);
        await connectBrowser();
        // FSEvents can report changes made just before the watch began.
        await Future<void>.delayed(_settleDuration);
        reloadMessages.clear();
      });

      tearDown(() async {
        await liveReload.close();
        await httpServer.close(force: true);
        await sandbox.delete(recursive: true);
      });

      Future<void> expectReload() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (reloadMessages.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(reloadMessages, ['reload']);
      }

      test('detects file modifications', () async {
        File(p.join(rootPath, 'index.html')).writeAsStringSync('changed');
        await expectReload();
      });

      test('detects changes inside nested directories', () async {
        File(p.join(rootPath, 'nested', 'deep', 'a.css'))
            .writeAsStringSync('a');
        await expectReload();
      });

      test('detects changes inside directories created later', () async {
        final createdDirectory = Directory(p.join(rootPath, 'created'))
          ..createSync();
        await expectReload();
        await Future<void>.delayed(_settleDuration);
        reloadMessages.clear();
        File(p.join(createdDirectory.path, 'a.css')).writeAsStringSync('a');
        await expectReload();
      });

      test('debounces rapid filesystem events', () async {
        for (var index = 0; index < 10; index++) {
          File(p.join(rootPath, 'file$index.css')).writeAsStringSync('$index');
        }
        await expectReload();
        await Future<void>.delayed(_settleDuration);
        expect(reloadMessages, hasLength(1));
      });

      test('ignores temporary and hidden files', () async {
        File(p.join(rootPath, 'index.html.swp')).writeAsStringSync('x');
        File(p.join(rootPath, '.git', 'index')).writeAsStringSync('x');
        await Future<void>.delayed(_settleDuration);
        expect(reloadMessages, isEmpty);
      });

      test('a browser can reconnect after disconnecting', () async {
        await browser.close();
        await connectBrowser();
        File(p.join(rootPath, 'index.html')).writeAsStringSync('changed');
        await expectReload();
      });
    });
  }

  group('server integration', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sito_reload_server_');
      File(p.join(root.path, 'index.html'))
          .writeAsStringSync('<body>home</body>');
      File(p.join(root.path, 'app.js')).writeAsStringSync('run("</body>")');
    });

    tearDown(() => root.delete(recursive: true));

    Future<SitoServer> startServer({required bool liveReloadEnabled}) async {
      final server = await SitoServer.start(
        resolvedRootPath: await root.resolveSymbolicLinks(),
        port: 0,
        liveReloadEnabled: liveReloadEnabled,
      );
      addTearDown(server.close);
      return server;
    }

    Future<HttpClientResponse> send(
      SitoServer server,
      String method,
      String path,
    ) async {
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.open(method, '127.0.0.1', server.port, path);
      return request.close();
    }

    Future<String> fetch(SitoServer server, String path) async {
      return utf8.decoder.bind(await send(server, 'GET', path)).join();
    }

    test('does not inject when reload is disabled', () async {
      final server = await startServer(liveReloadEnabled: false);
      expect(await fetch(server, '/'), '<body>home</body>');
    });

    test('the endpoint is an ordinary path when reload is disabled', () async {
      final server = await startServer(liveReloadEnabled: false);
      final response = await send(server, 'GET', reloadEndpointPath);
      await response.drain<void>();
      expect(response.statusCode, 404);
    });

    test('injects into HTML with a correct Content-Length', () async {
      final server = await startServer(liveReloadEnabled: true);
      final response = await send(server, 'GET', '/');
      final body = await utf8.decoder.bind(response).join();
      expect(body, contains('<script>'));
      expect(response.contentLength, body.length);

      final headResponse = await send(server, 'HEAD', '/');
      await headResponse.drain<void>();
      expect(headResponse.contentLength, body.length);
    });

    test('does not inject into non-HTML responses', () async {
      final server = await startServer(liveReloadEnabled: true);
      expect(await fetch(server, '/app.js'), 'run("</body>")');
    });

    test('does not modify project files', () async {
      final server = await startServer(liveReloadEnabled: true);
      await fetch(server, '/');
      expect(
        File(p.join(root.path, 'index.html')).readAsStringSync(),
        '<body>home</body>',
      );
    });

    test('sends reload messages over the reserved endpoint', () async {
      final server = await startServer(liveReloadEnabled: true);
      final browser = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}$reloadEndpointPath',
      );
      addTearDown(browser.close);
      final firstMessage = browser.first;
      await Future<void>.delayed(_settleDuration);
      File(p.join(root.path, 'index.html')).writeAsStringSync('changed');
      expect(await firstMessage.timeout(const Duration(seconds: 5)), 'reload');
    });

    test('rejects plain GET requests to the endpoint', () async {
      final server = await startServer(liveReloadEnabled: true);
      final response = await send(server, 'GET', reloadEndpointPath);
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.upgradeRequired);
    });
  });
}
