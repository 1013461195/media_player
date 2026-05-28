import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';
import 'utils.dart';

class ServerStore {
  static const _storage = FlutterSecureStorage();

  static Future<List<ServerConfig>> loadServers() async {
    final raw = await _storage.read(key: serversPrefKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((item) => ServerConfig.fromJson(item as Map<String, Object?>))
        .where((server) => server.id.isNotEmpty && server.host.isNotEmpty)
        .toList();
  }

  static Future<String?> loadLastServerId() async {
    return _storage.read(key: lastServerIdPrefKey);
  }

  static Future<void> saveLastServerId(String id) async {
    await _storage.write(key: lastServerIdPrefKey, value: id);
  }

  static Future<void> saveServer(ServerConfig server) async {
    final servers = await loadServers();
    final index = servers.indexWhere((item) => item.id == server.id);
    if (index >= 0) {
      servers[index] = server;
    } else {
      servers.add(server);
    }
    await _saveServers(servers);
  }

  static Future<void> deleteServer(String id) async {
    final servers = await loadServers();
    servers.removeWhere((item) => item.id == id);
    await _saveServers(servers);
  }

  static Future<void> _saveServers(List<ServerConfig> servers) async {
    await _storage.write(
      key: serversPrefKey,
      value: jsonEncode(servers.map((server) => server.toJson()).toList()),
    );
  }
}
