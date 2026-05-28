import 'package:flutter/services.dart';

class SmbNativeFile {
  const SmbNativeFile({
    required this.name,
    required this.path,
    required this.size,
    required this.isDirectory,
    required this.createTime,
    required this.lastModified,
    required this.isReadonly,
  });

  final String name;
  final String path;
  final int size;
  final bool isDirectory;
  final int createTime;
  final int lastModified;
  final bool isReadonly;

  static SmbNativeFile fromMap(Map<dynamic, dynamic> map) {
    return SmbNativeFile(
      name: map['name'] as String? ?? '',
      path: map['path'] as String? ?? '',
      size: map['size'] as int? ?? 0,
      isDirectory: map['isDirectory'] as bool? ?? false,
      createTime: map['createTime'] as int? ?? 0,
      lastModified: map['lastModified'] as int? ?? 0,
      isReadonly: map['isReadonly'] as bool? ?? false,
    );
  }
}

class SmbNativeClient {
  static const _channel = MethodChannel('com.huangjx.media_play/smb');

  String? _sessionId;
  String? get sessionId => _sessionId;
  bool get isConnected => _sessionId != null;

  Future<void> connect({
    required String host,
    required String domain,
    required String username,
    required String password,
  }) async {
    final sessionId = await _channel.invokeMethod<String>('smbConnect', {
      'host': host,
      'domain': domain,
      'username': username,
      'password': password,
    });
    if (sessionId == null) {
      throw Exception('SMB connection failed: no session ID returned');
    }
    _sessionId = sessionId;
  }

  Future<List<SmbNativeFile>> listFiles(String path) async {
    _assertConnected();
    final result = await _channel.invokeMethod<List<dynamic>>(
      'smbListFiles',
      {'sessionId': _sessionId, 'path': path},
    );
    if (result == null) return [];
    return result
        .map((item) => SmbNativeFile.fromMap(item as Map<dynamic, dynamic>))
        .toList();
  }

  Future<void> deleteFile(String path) async {
    _assertConnected();
    await _channel.invokeMethod<void>('smbDeleteFile', {
      'sessionId': _sessionId,
      'path': path,
    });
  }

  Future<int> getFileSize(String path) async {
    _assertConnected();
    final size = await _channel.invokeMethod<int>('smbGetFileSize', {
      'sessionId': _sessionId,
      'path': path,
    });
    return size ?? 0;
  }

  String getContentUri(String path) {
    _assertConnected();
    final encodedPath = Uri.encodeComponent(path);
    return 'content://com.huangjx.media_play.smb.provider/$_sessionId/$encodedPath';
  }

  Future<void> disconnect() async {
    if (_sessionId == null) return;
    try {
      await _channel.invokeMethod<void>('smbDisconnect', {
        'sessionId': _sessionId,
      });
    } catch (_) {}
    _sessionId = null;
  }

  void _assertConnected() {
    if (_sessionId == null) {
      throw Exception('SMB not connected');
    }
  }
}
