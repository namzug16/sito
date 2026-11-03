import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The WebSocket path reserved for live reload while `--reload` is active.
const reloadEndpointPath = '/__sito/reload';

const _reloadScript =
    '<script>(()=>{const connect=()=>{'
    'const socket=new WebSocket("ws://"+location.host+"$reloadEndpointPath");'
    'socket.onmessage=()=>location.reload();'
    'socket.onclose=()=>setTimeout(connect,1000)'
    '};connect()})()</script>';

const _temporaryFileSuffixes = ['~', '.swp', '.swx', '.tmp'];

/// Vim creates a file with this name to probe directory permissions.
const _vimProbeFileName = '4913';

/// Returns [htmlBytes] with the reload script before the last `</body>`, or at
/// the end when there is none. Works on bytes so that documents in any
/// ASCII-compatible encoding pass through untouched.
Uint8List injectReloadScript(List<int> htmlBytes) {
  final lowercaseHtml = latin1.decode(htmlBytes).toLowerCase();
  final closingBodyIndex = lowercaseHtml.lastIndexOf('</body');
  final insertionIndex = closingBodyIndex == -1
      ? htmlBytes.length
      : closingBodyIndex;
  return Uint8List.fromList([
    ...htmlBytes.take(insertionIndex),
    ...ascii.encode(_reloadScript),
    ...htmlBytes.skip(insertionIndex),
  ]);
}

/// Whether a change at [relativePath] (relative to the root) should reload
/// connected browsers.
bool isRelevantChange(String relativePath) {
  final segments = p.split(relativePath);
  if (segments.any(_isIgnoredDirectoryName)) return false;
  final fileName = segments.last;
  return fileName != _vimProbeFileName &&
      !_temporaryFileSuffixes.any(fileName.endsWith);
}

bool _isIgnoredDirectoryName(String name) =>
    name.startsWith('.') || name == 'node_modules';

/// Watches [resolvedRootPath] and tells connected browsers to reload.
class LiveReload {
  LiveReload(
    this.resolvedRootPath, {
    this.debounceDuration = const Duration(milliseconds: 100),
    bool? watchEachDirectory,
  }) : _watchEachDirectory = watchEachDirectory ?? Platform.isLinux;

  final String resolvedRootPath;
  final Duration debounceDuration;

  /// Recursive watching is not supported on Linux, so there every directory
  /// gets its own watch.
  final bool _watchEachDirectory;

  final _connectedBrowsers = <WebSocket>{};
  final _watchesByDirectoryPath =
      <String, StreamSubscription<FileSystemEvent>>{};
  Timer? _debounceTimer;
  bool _hasWarnedAboutWatchFailure = false;

  Future<void> start() async {
    if (_watchEachDirectory) {
      await _watchDirectoryTree(resolvedRootPath);
    } else {
      _watchDirectory(resolvedRootPath, recursive: true);
    }
  }

  Future<void> acceptBrowser(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      return request.response.close();
    }
    final browser = await WebSocketTransformer.upgrade(request);
    _connectedBrowsers.add(browser);
    browser.listen(
      null,
      onDone: () => _connectedBrowsers.remove(browser),
      onError: (_) => _connectedBrowsers.remove(browser),
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    _debounceTimer?.cancel();
    await Future.wait([
      for (final watch in _watchesByDirectoryPath.values) watch.cancel(),
      for (final browser in _connectedBrowsers) browser.close(),
    ]);
  }

  Future<void> _watchDirectoryTree(String directoryPath) async {
    if (_watchesByDirectoryPath.containsKey(directoryPath)) return;
    _watchDirectory(directoryPath, recursive: false);
    try {
      await for (final entity in Directory(
        directoryPath,
      ).list(followLinks: false)) {
        final isIgnored = _isIgnoredDirectoryName(p.basename(entity.path));
        if (entity is Directory && !isIgnored) {
          await _watchDirectoryTree(entity.path);
        }
      }
    } on FileSystemException catch (failure) {
      _warnAboutWatchFailure(failure);
    }
  }

  void _watchDirectory(String directoryPath, {required bool recursive}) {
    try {
      _watchesByDirectoryPath[directoryPath] = Directory(directoryPath)
          .watch(recursive: recursive)
          .listen(
            _handleFileSystemEvent,
            onError: _warnAboutWatchFailure,
            onDone: () => _watchesByDirectoryPath.remove(directoryPath),
          );
    } on FileSystemException catch (failure) {
      _warnAboutWatchFailure(failure);
    }
  }

  void _handleFileSystemEvent(FileSystemEvent event) {
    if (!p.isWithin(resolvedRootPath, event.path)) return;
    final relativePath = p.relative(event.path, from: resolvedRootPath);
    if (!isRelevantChange(relativePath)) return;
    if (_watchEachDirectory &&
        event is FileSystemCreateEvent &&
        event.isDirectory) {
      unawaited(_watchDirectoryTree(event.path));
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounceDuration, _reloadConnectedBrowsers);
  }

  void _reloadConnectedBrowsers() {
    for (final browser in _connectedBrowsers) {
      browser.add('reload');
    }
  }

  void _warnAboutWatchFailure(Object failure) {
    if (_hasWarnedAboutWatchFailure) return;
    _hasWarnedAboutWatchFailure = true;
    stderr.writeln(
      'Warning: Could not watch every directory, so live reload may miss '
      'changes. On Linux, raise fs.inotify.max_user_watches.',
    );
  }
}
