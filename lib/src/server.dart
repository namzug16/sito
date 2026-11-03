import 'dart:async';
import 'dart:io';

import 'reload.dart';
import 'static_handler.dart';

const _loopbackHostNames = {'localhost', '127.0.0.1', '[::1]'};

/// A running static server for the directory at [resolvedRootPath].
class SitoServer {
  SitoServer._(this._httpServer, this._staticHandler, this._liveReload);

  final HttpServer _httpServer;
  final StaticHandler _staticHandler;
  final LiveReload? _liveReload;

  /// Binds the server. [host] defaults to loopback so nothing is exposed to
  /// the network unless the user asks for it.
  ///
  /// shortcut: binds IPv4 only, so another process on [::1] with the same port
  /// can capture `localhost`; bind both families if that bites in practice.
  static Future<SitoServer> start({
    required String resolvedRootPath,
    required int port,
    String host = '127.0.0.1',
    bool liveReloadEnabled = false,
  }) async {
    final httpServer = await HttpServer.bind(host, port);
    httpServer.defaultResponseHeaders.clear();
    final liveReload = liveReloadEnabled ? LiveReload(resolvedRootPath) : null;
    await liveReload?.start();
    final server = SitoServer._(
      httpServer,
      StaticHandler(resolvedRootPath, liveReloadEnabled: liveReloadEnabled),
      liveReload,
    );
    httpServer.listen(server._handleRequestSafely);
    return server;
  }

  InternetAddress get address => _httpServer.address;

  int get port => _httpServer.port;

  Future<void> close() async {
    await _liveReload?.close();
    await _httpServer.close(force: true);
  }

  Future<void> _handleRequestSafely(HttpRequest request) async {
    try {
      await _handleRequest(request);
    } on IOException {
      // The browser went away mid-response; there is nobody left to answer.
      unawaited(request.response.close().catchError((_) {}));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!_isAllowedHost(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      return request.response.close();
    }
    final liveReload = _liveReload;
    if (liveReload != null && request.uri.path == reloadEndpointPath) {
      return liveReload.acceptBrowser(request);
    }
    return _staticHandler.handleRequest(request);
  }

  /// Blocks DNS rebinding, where a hostile site points its own domain at
  /// 127.0.0.1 to read local files through the visitor's browser.
  bool _isAllowedHost(HttpRequest request) {
    if (!address.isLoopback) return true;
    return _loopbackHostNames.contains(request.headers.host?.toLowerCase());
  }
}
