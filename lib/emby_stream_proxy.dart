import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'smb_stream_server.dart';
import 'utils.dart';

class EmbyStreamProbe {
  const EmbyStreamProbe({required this.total, required this.contentType});

  final int total;
  final String contentType;
}

class EmbyStreamStats {
  const EmbyStreamStats({
    required this.bytesPerSecond,
    required this.activeConnections,
  });

  final int bytesPerSecond;
  final int activeConnections;
}

class _EmbyChunkCache {
  static const int chunkSize = 2 * 1024 * 1024;

  _EmbyChunkCache({int maxChunks = 48}) : _maxChunks = maxChunks;

  final int _maxChunks;
  final Map<int, Uint8List> _cache = {};
  final Map<int, Future<Uint8List>> _pending = {};
  final List<int> _accessOrder = [];

  Uint8List? get(int chunkIndex) {
    final data = _cache[chunkIndex];
    if (data != null) {
      _accessOrder.remove(chunkIndex);
      _accessOrder.add(chunkIndex);
    }
    return data;
  }

  Future<Uint8List>? pending(int chunkIndex) => _pending[chunkIndex];

  Future<Uint8List> track(int chunkIndex, Future<Uint8List> Function() loader) {
    final cached = get(chunkIndex);
    if (cached != null) {
      return Future.value(cached);
    }
    final existing = _pending[chunkIndex];
    if (existing != null) {
      return existing;
    }
    final future = loader();
    _pending[chunkIndex] = future;
    future
        .then((data) {
          put(chunkIndex, data);
        })
        .catchError((_) {})
        .whenComplete(() {
          _pending.remove(chunkIndex);
        });
    return future;
  }

  void put(int chunkIndex, Uint8List data) {
    if (_cache.containsKey(chunkIndex)) {
      _accessOrder.remove(chunkIndex);
    }
    _cache[chunkIndex] = data;
    _accessOrder.add(chunkIndex);
    while (_cache.length > _maxChunks) {
      final oldest = _accessOrder.removeAt(0);
      _cache.remove(oldest);
    }
  }
}

class _EmbyProxyEntry {
  _EmbyProxyEntry({
    required this.source,
    required this.fileName,
    required this.probe,
  }) : cache = _EmbyChunkCache();

  final Uri source;
  final String fileName;
  final EmbyStreamProbe probe;
  final _EmbyChunkCache cache;
}

class LocalEmbyStreamProxy {
  LocalEmbyStreamProxy({this.prefetchChunks = 16, this.maxConnections = 8}) {
    _client.maxConnectionsPerHost = maxConnections;
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final bytes = _bytesThisSecond;
      _bytesThisSecond = 0;
      if (!_statsController.isClosed) {
        _statsController.add(
          EmbyStreamStats(
            bytesPerSecond: bytes,
            activeConnections: _activeConnections,
          ),
        );
      }
    });
  }

  final int prefetchChunks;
  final int maxConnections;
  final HttpClient _client = HttpClient();
  final Map<String, _EmbyProxyEntry> _entries = {};
  final StreamController<EmbyStreamStats> _statsController =
      StreamController.broadcast();
  Timer? _speedTimer;
  int _bytesThisSecond = 0;
  int _activeConnections = 0;
  HttpServer? _server;

  Stream<EmbyStreamStats> get statsStream => _statsController.stream;

  Future<Uri> urlFor(Uri source, {required String fileName}) async {
    await _ensureStarted();
    final probe = await _probe(source, fileName);
    debugPrint(
      '[EmbyProxy] enabled: maxConnections=$maxConnections, '
      'prefetchChunks=$prefetchChunks, chunkSize=${_EmbyChunkCache.chunkSize}, '
      'total=${probe.total}, source=$source',
    );
    final token = base64Url
        .encode(utf8.encode('$source:${DateTime.now().microsecondsSinceEpoch}'))
        .replaceAll('=', '');
    _entries[token] = _EmbyProxyEntry(
      source: source,
      fileName: fileName,
      probe: probe,
    );

    final server = _server!;
    final entry = _entries[token]!;
    _prefetchChunk(entry, 0);
    for (var i = 1; i < prefetchChunks; i++) {
      _prefetchChunk(entry, i);
    }

    return Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      pathSegments: ['emby', token, fileName],
    );
  }

  Future<void> _ensureStarted() async {
    if (_server != null) {
      return;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(server.listen(_handleRequest).asFuture<void>());
  }

  Future<void> close() async {
    _entries.clear();
    await _server?.close(force: true);
    _server = null;
    _speedTimer?.cancel();
    _client.close(force: true);
    await _statsController.close();
  }

  Future<EmbyStreamProbe> _probe(Uri source, String fileName) async {
    try {
      final request = await _client.headUrl(source);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode >= 200 &&
          response.statusCode < 400 &&
          response.contentLength > 0) {
        return EmbyStreamProbe(
          total: response.contentLength,
          contentType:
              response.headers.contentType?.mimeType ??
              contentTypeFor(fileName),
        );
      }
    } catch (_) {
      // Fall back to a ranged GET below. Some Emby/reverse proxy setups do not
      // answer HEAD consistently for video streams.
    }

    final request = await _client.getUrl(source);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close();
    await response.drain<void>();
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = RegExp(
      r'^bytes \d+-\d+/(\d+)$',
    ).firstMatch(contentRange ?? '');
    final total = match == null ? response.contentLength : int.parse(match[1]!);
    if (total <= 0) {
      throw const HttpException('无法探测 Emby 视频文件大小，不能启用多线程代理');
    }
    return EmbyStreamProbe(
      total: total,
      contentType:
          response.headers.contentType?.mimeType ?? contentTypeFor(fileName),
    );
  }

  Future<Uint8List> _readChunk(_EmbyProxyEntry entry, int chunkIndex) {
    final total = entry.probe.total;
    final chunkSize = _EmbyChunkCache.chunkSize;
    final start = chunkIndex * chunkSize;
    if (start >= total) {
      return Future.value(Uint8List(0));
    }
    return entry.cache.track(chunkIndex, () async {
      final end = (start + chunkSize - 1).clamp(start, total - 1).toInt();
      _activeConnections += 1;
      debugPrint(
        '[EmbyProxy] chunk#$chunkIndex start bytes=$start-$end '
        'active=$_activeConnections',
      );
      try {
        final request = await _client.getUrl(entry.source);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
        final response = await request.close();
        final acceptsWholeFile =
            response.statusCode == HttpStatus.ok &&
            start == 0 &&
            end == total - 1;
        if (response.statusCode != HttpStatus.partialContent &&
            !acceptsWholeFile) {
          await response.drain<void>();
          throw HttpException(
            'Emby 分块请求失败: HTTP ${response.statusCode}',
            uri: entry.source,
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          bytes.add(chunk);
          _bytesThisSecond += chunk.length;
        }
        final data = bytes.takeBytes();
        debugPrint(
          '[EmbyProxy] chunk#$chunkIndex done bytes=${data.length} '
          'status=${response.statusCode}',
        );
        return data;
      } catch (error) {
        debugPrint('[EmbyProxy] chunk#$chunkIndex failed: $error');
        rethrow;
      } finally {
        _activeConnections -= 1;
      }
    });
  }

  void _prefetchChunk(_EmbyProxyEntry entry, int chunkIndex) {
    unawaited(_readChunk(entry, chunkIndex).catchError((_) => Uint8List(0)));
  }

  void _prefetch(_EmbyProxyEntry entry, int currentChunk) {
    final totalChunks =
        (entry.probe.total + _EmbyChunkCache.chunkSize - 1) ~/
        _EmbyChunkCache.chunkSize;
    final end = (currentChunk + prefetchChunks).clamp(0, totalChunks).toInt();
    for (var i = currentChunk + 1; i < end; i++) {
      if (entry.cache.get(i) == null && entry.cache.pending(i) == null) {
        _prefetchChunk(entry, i);
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    var responseBodyStarted = false;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments.first != 'emby') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final entry = _entries[segments[1]];
      if (entry == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final total = entry.probe.total;
      final range = parseRange(
        request.headers.value(HttpHeaders.rangeHeader),
        total,
      );
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await response.close();
        return;
      }

      final hasRange = request.headers.value(HttpHeaders.rangeHeader) != null;
      response.statusCode = hasRange
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, entry.probe.contentType)
        ..set(HttpHeaders.contentLengthHeader, range.length);
      if (hasRange) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.endInclusive}/$total',
        );
      }

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      responseBodyStarted = true;
      final chunkSize = _EmbyChunkCache.chunkSize;
      final startChunk = range.start ~/ chunkSize;
      final endChunk = range.endInclusive ~/ chunkSize;
      debugPrint(
        '[EmbyProxy] local ${request.method} '
        'range=${range.start}-${range.endInclusive} '
        'chunks=$startChunk-$endChunk',
      );

      _prefetch(entry, startChunk - 1);

      for (var i = startChunk; i <= endChunk; i++) {
        _prefetch(entry, i);
        final chunkData = await _readChunk(entry, i);
        final chunkStart = i * chunkSize;
        final chunkEnd = chunkStart + chunkData.length;
        final readStart =
            (range.start > chunkStart ? range.start : chunkStart) - chunkStart;
        final readEndRaw =
            (range.endExclusive < chunkEnd ? range.endExclusive : chunkEnd) -
            chunkStart;

        if (readStart < readEndRaw && readStart < chunkData.length) {
          final actualEnd = readEndRaw < chunkData.length
              ? readEndRaw
              : chunkData.length;
          response.add(chunkData.sublist(readStart, actualEnd));
        }
      }

      await response.flush();
      await response.close();
    } catch (_) {
      if (!responseBodyStarted) {
        try {
          response.statusCode = HttpStatus.internalServerError;
          await response.close();
        } catch (_) {}
      } else {
        try {
          await response.close();
        } catch (_) {}
      }
    }
  }
}
