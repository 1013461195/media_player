import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'utils.dart';

class ServerStore {
  static Future<SharedPreferences> get _prefs async =>
      SharedPreferences.getInstance();

  static Future<List<ServerConfig>> loadServers() async {
    final prefs = await _prefs;
    final raw = prefs.getString(serversPrefKey);
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
    final prefs = await _prefs;
    return prefs.getString(lastServerIdPrefKey);
  }

  static Future<void> saveLastServerId(String id) async {
    final prefs = await _prefs;
    await prefs.setString(lastServerIdPrefKey, id);
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
    final prefs = await _prefs;
    await prefs.setString(
      serversPrefKey,
      jsonEncode(servers.map((server) => server.toJson()).toList()),
    );
  }
}
