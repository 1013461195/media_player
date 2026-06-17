import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';

import 'emby_client.dart';
import 'models.dart';
import 'pages/browser_page.dart';
import 'pages/emby_home_page.dart';
import 'pages/server_home_page.dart';
import 'pages/settings_page.dart';
import 'server_store.dart';
import 'utils.dart';
import 'widgets/common.dart';

Future<void> openAppTab(
  BuildContext context,
  AppTab tab, {
  required AppTab active,
  ServerConfig? currentServer,
}) async {
  if (tab == active) {
    return;
  }

  switch (tab) {
    case AppTab.servers:
      _replace(context, const ServerHomePage(autoConnect: false));
    case AppTab.settings:
      _replace(context, const SettingsPage());
    case AppTab.media:
      await _openServerKind(context, ServerKind.emby, currentServer);
    case AppTab.files:
      await _openServerKind(context, ServerKind.smb, currentServer);
  }
}

Future<void> _openServerKind(
  BuildContext context,
  ServerKind kind,
  ServerConfig? currentServer,
) async {
  final server = await _preferredServer(kind, currentServer);
  if (server == null) {
    if (context.mounted) {
      final label = kind == ServerKind.emby ? '媒体库' : '文件源';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('还没有可打开的$label服务器，请先添加')));
      _replace(context, const ServerHomePage(autoConnect: false));
    }
    return;
  }

  try {
    if (kind == ServerKind.emby) {
      final client = await EmbyClient(server).authenticate();
      await ServerStore.saveServer(client.config);
      await ServerStore.saveLastServerId(client.config.id);
      if (context.mounted) {
        _replace(context, EmbyHomePage(client: client));
      }
      return;
    }

    final client = await SmbConnect.connectAuth(
      host: server.host.trim(),
      domain: server.domain.trim(),
      username: server.username.trim(),
      password: server.password,
    );
    await ServerStore.saveLastServerId(server.id);
    if (context.mounted) {
      _replace(context, BrowserPage(client: client, server: server));
    } else {
      await client.close();
    }
  } catch (error) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('切换失败：${friendlyError(error)}')));
  }
}

Future<ServerConfig?> _preferredServer(
  ServerKind kind,
  ServerConfig? currentServer,
) async {
  if (currentServer?.kind == kind) {
    return currentServer;
  }
  final servers = await ServerStore.loadServers();
  final lastId = await ServerStore.loadLastServerId();
  final last = servers
      .where((server) => server.kind == kind && server.id == lastId)
      .firstOrNull;
  if (last != null) {
    return last;
  }
  return servers.where((server) => server.kind == kind).firstOrNull;
}

void _replace(BuildContext context, Widget page) {
  Navigator.of(
    context,
  ).pushReplacement(MaterialPageRoute<void>(builder: (_) => page));
}
