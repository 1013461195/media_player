import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/smb_connect.dart';

import 'utils.dart';

class ByteRange {
  const ByteRange(this.start, this.endInclusive);

  final int start;
  final int endInclusive;

  int get endExclusive => endInclusive + 1;
  int get length => endExclusive - start;
}

ByteRange? parseRange(String? header, int total) {
  if (total <= 0) {
    return null;
  }
  if (header == null || header.isEmpty) {
    return ByteRange(0, total - 1);
  }
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) {
    return null;
  }

  final startText = match.group(1)!;
  final endText = match.group(2)!;
  if (startText.isEmpty && endText.isEmpty) {
    return null;
  }

  int start;
  int end;
  if (startText.isEmpty) {
    final suffixLength = int.tryParse(endText);
    if (suffixLength == null || suffixLength <= 0) {
      return null;
    }
    start = (total - suffixLength).clamp(0, total - 1).toInt();
    end = total - 1;
  } else {
    start = int.tryParse(startText) ?? -1;
    end = endText.isEmpty ? total - 1 : int.tryParse(endText) ?? -1;
    if (start < 0 || end < start || start >= total) {
      return null;
    }
    end = end.clamp(start, total - 1).toInt();
  }

  return ByteRange(start, end);
}

Future<Uint8List> readSmbBytes(SmbConnect client, SmbFile file) async {
  final chunks = await client.openRead(file);
  final bytes = BytesBuilder();
  await for (final chunk in chunks) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

// Chunk-based cache for SMB file reads
class _ChunkCache {
  static const int chunkSize = 512 * 1024; // 512KB per chunk
  final Map<int, Uint8List> _cache = {};
  final int _maxChunks;
  final List<int> _accessOrder = [];

  _ChunkCache({int maxChunks = 64}) : _maxChunks = maxChunks;

  Uint8List? get(int chunkIndex) {
    final data = _cache[chunkIndex];
    if (data != null) {
      _accessOrder.remove(chunkIndex);
      _accessOrder.add(chunkIndex);
    }
    return data;
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

class LocalSmbStreamServer {
  LocalSmbStreamServer(this.client);

  final SmbConnect client;
  final Map<String, SmbFile> _files = {};
  final Map<String, _ChunkCache> _caches = {};
  HttpServer? _server;

  Future<Uri> urlFor(SmbFile file) async {
    await _ensureStarted();
    final token = base64Url
        .encode(
          utf8.encode('${file.path}:${DateTime.now().microsecondsSinceEpoch}'),
        )
        .replaceAll('=', '');
    _files[token] = file;
    _caches[token] = _ChunkCache();
    final server = _server!;
    return Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      pathSegments: ['video', token, file.name],
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
    _files.clear();
    _caches.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<Uint8List> _readChunk(
    SmbFile file,
    _ChunkCache cache,
    int chunkIndex,
  ) async {
    final cached = cache.get(chunkIndex);
    if (cached != null) {
      return cached;
    }

    final chunkSize = _ChunkCache.chunkSize;
    final start = chunkIndex * chunkSize;
    final endExclusive = start + chunkSize;
    final end = endExclusive > file.size ? file.size : endExclusive;

    final chunks = await client.openRead(file, start, end);
    final bytes = BytesBuilder();
    await for (final chunk in chunks) {
      bytes.add(chunk);
    }
    final data = bytes.takeBytes();
    cache.put(chunkIndex, data);
    return data;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    var responseBodyStarted = false;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments.first != 'video') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final token = segments[1];
      final file = _files[token];
      final cache = _caches[token];
      if (file == null || cache == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final total = file.size;
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

      final hasRange =
          request.headers.value(HttpHeaders.rangeHeader) != null;
      response.statusCode =
          hasRange ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, contentTypeFor(file.name))
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

      // Use chunk-based reading for better performance
      final chunkSize = _ChunkCache.chunkSize;
      final startChunk = range.start ~/ chunkSize;
      final endChunk = range.endInclusive ~/ chunkSize;

      for (var i = startChunk; i <= endChunk; i++) {
        final chunkData = await _readChunk(file, cache, i);
        final chunkStart = i * chunkSize;
        final chunkEnd = chunkStart + chunkData.length;

        // Calculate the overlap with the requested range
        final readStart =
            (range.start > chunkStart ? range.start : chunkStart) - chunkStart;
        final readEndRaw = (range.endExclusive < chunkEnd
                ? range.endExclusive
                : chunkEnd) -
            chunkStart;

        if (readStart < readEndRaw && readStart < chunkData.length) {
          final actualEnd =
              readEndRaw < chunkData.length ? readEndRaw : chunkData.length;
          response.add(chunkData.sublist(readStart, actualEnd));
        }
      }

      await response.flush();
      await response.close();
    } catch (error) {
      if (!responseBodyStarted) {
        try {
          response.statusCode = HttpStatus.internalServerError;
          await response.close();
        } catch (_) {}
      }
    }
  }
}
