import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

const _unsatisfiableByteRange = (firstByte: -1, lastByte: -1);

/// Serves files below [resolvedRootPath], which must already have its symbolic
/// links resolved so that containment checks compare like with like.
class StaticHandler {
  StaticHandler(this.resolvedRootPath);

  final String resolvedRootPath;

  Future<void> handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

    if (request.method != 'GET' && request.method != 'HEAD') {
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      return _respondWithStatus(response, HttpStatus.methodNotAllowed);
    }

    final requestedPath = _pathForUrlSegments(request.uri.pathSegments);
    final resolvedPath = requestedPath == null
        ? null
        : await _resolveInsideRoot(requestedPath);
    if (resolvedPath == null) {
      return _respondWithStatus(response, HttpStatus.notFound);
    }

    if (await FileSystemEntity.isFile(resolvedPath)) {
      return _sendFile(request, File(resolvedPath));
    }

    if (!request.uri.path.endsWith('/')) {
      final query = request.uri.hasQuery ? '?${request.uri.query}' : '';
      response.headers.set(
        HttpHeaders.locationHeader,
        '${request.uri.path}/$query',
      );
      return _respondWithStatus(response, HttpStatus.found);
    }

    final resolvedIndexPath = await _resolveInsideRoot(
      p.join(resolvedPath, 'index.html'),
    );
    if (resolvedIndexPath == null ||
        !await FileSystemEntity.isFile(resolvedIndexPath)) {
      return _respondWithStatus(response, HttpStatus.notFound);
    }
    return _sendFile(request, File(resolvedIndexPath));
  }

  String? _pathForUrlSegments(List<String> decodedSegments) {
    final hasUnsafeSegment = decodedSegments.any(
      (segment) =>
          segment.contains('/') ||
          segment.contains(r'\') ||
          segment.contains('\x00'),
    );
    if (hasUnsafeSegment || _hasHiddenSegment(decodedSegments)) return null;
    return p.joinAll([resolvedRootPath, ...decodedSegments]);
  }

  /// Returns the real path of [candidatePath], or null when it does not exist,
  /// is hidden, or a symbolic link leads it outside the root.
  Future<String?> _resolveInsideRoot(String candidatePath) async {
    final String resolvedPath;
    try {
      resolvedPath = await File(candidatePath).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
    if (resolvedPath == resolvedRootPath) return resolvedPath;
    if (!p.isWithin(resolvedRootPath, resolvedPath)) return null;
    final relativeSegments = p.split(
      p.relative(resolvedPath, from: resolvedRootPath),
    );
    return _hasHiddenSegment(relativeSegments) ? null : resolvedPath;
  }

  bool _hasHiddenSegment(List<String> segments) {
    for (final (index, segment) in segments.indexed) {
      if (!segment.startsWith('.')) continue;
      if (index == 0 && segment == '.well-known') continue;
      return true;
    }
    return false;
  }

  Future<void> _sendFile(HttpRequest request, File file) async {
    final response = request.response;
    final mediaType = lookupMimeType(file.path) ?? 'application/octet-stream';
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentTypeHeaderValue(mediaType),
    );

    try {
      await (await file.open()).close();
    } on FileSystemException {
      response.headers.removeAll(HttpHeaders.contentTypeHeader);
      return _respondWithStatus(response, HttpStatus.forbidden);
    }

    final fileLength = await file.length();
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

    final byteRange = request.method == 'GET'
        ? _parseSingleByteRange(
            request.headers.value(HttpHeaders.rangeHeader),
            fileLength,
          )
        : null;

    if (byteRange == _unsatisfiableByteRange) {
      response.headers.removeAll(HttpHeaders.contentTypeHeader);
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$fileLength',
      );
      return _respondWithStatus(
        response,
        HttpStatus.requestedRangeNotSatisfiable,
      );
    }

    if (byteRange != null) {
      final (:firstByte, :lastByte) = byteRange;
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $firstByte-$lastByte/$fileLength',
      );
      response.contentLength = lastByte - firstByte + 1;
      await response.addStream(file.openRead(firstByte, lastByte + 1));
    } else {
      response.contentLength = fileLength;
      if (request.method == 'GET') await response.addStream(file.openRead());
    }
    await response.close();
  }

  String _contentTypeHeaderValue(String mediaType) {
    final isText =
        mediaType.startsWith('text/') || mediaType == 'application/json';
    return isText ? '$mediaType; charset=utf-8' : mediaType;
  }

  /// Parses a `Range` header. Absent, malformed and multi-range headers return
  /// null, which means the whole file is served.
  ({int firstByte, int lastByte})? _parseSingleByteRange(
    String? rangeHeader,
    int fileLength,
  ) {
    if (rangeHeader == null) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader.trim());
    if (match == null) return null;
    final firstByteText = match[1]!;
    final lastByteText = match[2]!;
    if (firstByteText.isEmpty && lastByteText.isEmpty) return null;

    if (firstByteText.isEmpty) {
      final suffixLength = int.tryParse(lastByteText);
      if (suffixLength == null) return null;
      if (suffixLength == 0 || fileLength == 0) return _unsatisfiableByteRange;
      final firstByte = suffixLength >= fileLength
          ? 0
          : fileLength - suffixLength;
      return (firstByte: firstByte, lastByte: fileLength - 1);
    }

    final firstByte = int.tryParse(firstByteText);
    if (firstByte == null) return null;
    final requestedLastByte = lastByteText.isEmpty
        ? fileLength - 1
        : int.tryParse(lastByteText);
    if (requestedLastByte == null) return null;
    if (lastByteText.isNotEmpty && requestedLastByte < firstByte) return null;
    if (firstByte >= fileLength) return _unsatisfiableByteRange;
    return (
      firstByte: firstByte,
      lastByte: requestedLastByte < fileLength
          ? requestedLastByte
          : fileLength - 1,
    );
  }

  Future<void> _respondWithStatus(HttpResponse response, int statusCode) {
    response.statusCode = statusCode;
    return response.close();
  }
}
