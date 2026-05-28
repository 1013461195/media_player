import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:smb_connect/smb_connect.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import 'package:volume_controller/volume_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const NasPlayerApp());
}

const _imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.bmp',
  '.webp',
  '.heic',
};

const _videoExtensions = {
  '.mp4',
  '.m4v',
  '.mov',
  '.mkv',
  '.avi',
  '.webm',
  '.ts',
  '.m2ts',
  '.flv',
  '.wmv',
};

const _smbDirectoryAttribute = 0x10;
const _serversPrefKey = 'nas_servers';
const _lastServerIdPrefKey = 'last_server_id';

enum VideoGestureMode { none, seek, brightness, volume }

enum ServerKind { smb, emby }

enum FileListViewMode { list, detail, largeGrid, mediumGrid }

enum EmbyLibraryView { programs, genres, folders }

class NasPlayerApp extends StatelessWidget {
  const NasPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Media Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff0f766e),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
        ),
        listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.zero),
      ),
      home: const ServerHomePage(),
    );
  }
}

class ServerConfig {
  const ServerConfig({
    required this.id,
    required this.kind,
    required this.name,
    required this.host,
    required this.domain,
    required this.username,
    required this.password,
    required this.accessToken,
    required this.userId,
  });

  final String id;
  final ServerKind kind;
  final String name;
  final String host;
  final String domain;
  final String username;
  final String password;
  final String accessToken;
  final String userId;

  String get displayName => name.trim().isEmpty ? host : name;

  ServerConfig copyWith({
    String? id,
    ServerKind? kind,
    String? name,
    String? host,
    String? domain,
    String? username,
    String? password,
    String? accessToken,
    String? userId,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      name: name ?? this.name,
      host: host ?? this.host,
      domain: domain ?? this.domain,
      username: username ?? this.username,
      password: password ?? this.password,
      accessToken: accessToken ?? this.accessToken,
      userId: userId ?? this.userId,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'host': host,
    'domain': domain,
    'username': username,
    'password': password,
    'accessToken': accessToken,
    'userId': userId,
  };

  static ServerConfig fromJson(Map<String, Object?> json) {
    return ServerConfig(
      id: json['id'] as String? ?? '',
      kind: ServerKind.values.firstWhere(
        (kind) => kind.name == (json['kind'] as String? ?? 'smb'),
        orElse: () => ServerKind.smb,
      ),
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
    );
  }
}

class ServerStore {
  static const _storage = FlutterSecureStorage();

  static Future<List<ServerConfig>> loadServers() async {
    final raw = await _storage.read(key: _serversPrefKey);
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
    return _storage.read(key: _lastServerIdPrefKey);
  }

  static Future<void> saveLastServerId(String id) async {
    await _storage.write(key: _lastServerIdPrefKey, value: id);
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

  static Future<void> _saveServers(List<ServerConfig> servers) async {
    await _storage.write(
      key: _serversPrefKey,
      value: jsonEncode(servers.map((server) => server.toJson()).toList()),
    );
  }
}

class ServerHomePage extends StatefulWidget {
  const ServerHomePage({super.key});

  @override
  State<ServerHomePage> createState() => _ServerHomePageState();
}

class _ServerHomePageState extends State<ServerHomePage> {
  late Future<List<ServerConfig>> _serversFuture;
  bool _isConnecting = false;
  String? _connectingId;

  @override
  void initState() {
    super.initState();
    _serversFuture = _loadAndMaybeAutoConnect();
  }

  Future<List<ServerConfig>> _loadAndMaybeAutoConnect() async {
    final servers = await ServerStore.loadServers();
    final lastId = await ServerStore.loadLastServerId();
    final last = servers.where((server) => server.id == lastId).firstOrNull;
    if (last != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _connect(last);
        }
      });
    }
    return servers;
  }

  void _reloadServers() {
    setState(() {
      _serversFuture = ServerStore.loadServers();
    });
  }

  Future<void> _connect(ServerConfig server) async {
    if (_isConnecting) {
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectingId = server.id;
    });
    try {
      if (server.kind == ServerKind.emby) {
        final client = EmbyClient(server);
        final authenticated = await client.authenticate();
        await ServerStore.saveServer(authenticated.config);
        await ServerStore.saveLastServerId(authenticated.config.id);
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => EmbyHomePage(client: authenticated),
          ),
        );
        return;
      }

      final client = await SmbConnect.connectAuth(
        host: server.host.trim(),
        domain: server.domain.trim(),
        username: server.username.trim(),
        password: server.password,
      );
      await ServerStore.saveLastServerId(server.id);
      if (!mounted) {
        await client.close();
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BrowserPage(client: client, server: server),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('连接失败：${_friendlyError(error)}')));
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _connectingId = null;
        });
      }
    }
  }

  Future<void> _addServer() async {
    final server = await showServerEditor(context);
    if (server == null) {
      return;
    }
    await ServerStore.saveServer(server);
    _reloadServers();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.video_library_outlined,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Media Player',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '选择一个服务器继续播放',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  IconButton.filled(
                    tooltip: '添加服务器',
                    icon: const Icon(Icons.add),
                    onPressed: _addServer,
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Expanded(
                child: FutureBuilder<List<ServerConfig>>(
                  future: _serversFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final servers = snapshot.data ?? const <ServerConfig>[];
                    if (servers.isEmpty) {
                      return EmptyServerState(onAdd: _addServer);
                    }
                    return ListView.separated(
                      itemCount: servers.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final server = servers[index];
                        final connecting =
                            _isConnecting && _connectingId == server.id;
                        return ServerTile(
                          server: server,
                          isConnecting: connecting,
                          onTap: () => _connect(server),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyServerState extends StatelessWidget {
  const EmptyServerState({required this.onAdd, super.key});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 54,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text('还没有服务器', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('添加 NAS 后会自动记住，下次打开直接进入上次服务器'),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ],
      ),
    );
  }
}

class ServerTile extends StatelessWidget {
  const ServerTile({
    required this.server,
    required this.isConnecting,
    required this.onTap,
    this.trailing,
    super.key,
  });

  final ServerConfig server;
  final bool isConnecting;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: isConnecting ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                child: Text(server.displayName.characters.first.toUpperCase()),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${server.kind == ServerKind.emby ? 'Emby' : 'SMB'} · ${server.username}@${server.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              isConnecting
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : trailing ?? const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class MediaFileTile extends StatelessWidget {
  const MediaFileTile({
    required this.file,
    required this.onTap,
    required this.client,
    required this.streamServer,
    this.compact = false,
    this.grid = false,
    super.key,
  });

  final SmbFile file;
  final VoidCallback onTap;
  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final bool compact;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    final isFolder = file.isDirectory();
    final isImage = _isImage(file);
    final colorScheme = Theme.of(context).colorScheme;
    final icon = isFolder
        ? Icons.folder_outlined
        : isImage
        ? Icons.image_outlined
        : Icons.movie_outlined;
    final color = isFolder
        ? colorScheme.primary
        : isImage
        ? const Color(0xffca8a04)
        : const Color(0xff2563eb);

    if (grid) {
      return Card(
        elevation: 0,
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SmbThumbnail(
                  file: file,
                  client: client,
                  streamServer: streamServer,
                  fallbackIcon: icon,
                  color: color,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Text(
                  file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: compact ? 42 : 64,
                height: compact ? 42 : 64,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SmbThumbnail(
                  file: file,
                  client: client,
                  streamServer: streamServer,
                  fallbackIcon: icon,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    if (!compact) ...[
                      const SizedBox(height: 2),
                      Text(
                        isFolder
                            ? '文件夹'
                            : '${isImage ? '图片' : '视频'} · ${_formatBytes(file.size)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(isFolder ? Icons.chevron_right : Icons.open_in_full),
            ],
          ),
        ),
      ),
    );
  }
}

class SmbThumbnail extends StatelessWidget {
  const SmbThumbnail({
    required this.file,
    required this.client,
    required this.streamServer,
    required this.fallbackIcon,
    required this.color,
    super.key,
  });

  final SmbFile file;
  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final IconData fallbackIcon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (file.isDirectory()) {
      return _fallback();
    }
    if (_isImage(file)) {
      return FutureBuilder<Uint8List>(
        future: _readSmbBytes(client, file),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(),
            );
          }
          return _fallback(
            loading: snapshot.connectionState != ConnectionState.done,
          );
        },
      );
    }
    if (_isVideo(file)) {
      return FutureBuilder<Uint8List?>(
        future: _videoThumbnail(),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(snapshot.data!, fit: BoxFit.cover),
                const Center(
                  child: Icon(
                    Icons.play_circle_fill,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ],
            );
          }
          return _fallback(
            loading: snapshot.connectionState != ConnectionState.done,
          );
        },
      );
    }
    return _fallback();
  }

  Future<Uint8List?> _videoThumbnail() async {
    final uri = await streamServer.urlFor(file);
    return VideoThumbnail.thumbnailData(
      video: uri.toString(),
      imageFormat: ImageFormat.JPEG,
      maxWidth: 320,
      quality: 70,
    );
  }

  Widget _fallback({bool loading = false}) {
    return Container(
      color: color.withValues(alpha: 0.13),
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(fallbackIcon, color: color),
      ),
    );
  }
}

Future<ServerConfig?> showServerEditor(
  BuildContext context, {
  ServerConfig? initial,
}) {
  return showModalBottomSheet<ServerConfig>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ServerEditorSheet(initial: initial),
  );
}

class ServerEditorSheet extends StatefulWidget {
  const ServerEditorSheet({this.initial, super.key});

  final ServerConfig? initial;

  @override
  State<ServerEditorSheet> createState() => _ServerEditorSheetState();
}

class _ServerEditorSheetState extends State<ServerEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late ServerKind _kind = widget.initial?.kind ?? ServerKind.smb;
  late final _nameController = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final _hostController = TextEditingController(
    text: widget.initial?.host ?? '',
  );
  late final _domainController = TextEditingController(
    text: widget.initial?.domain ?? '',
  );
  late final _usernameController = TextEditingController(
    text: widget.initial?.username ?? '',
  );
  late final _passwordController = TextEditingController(
    text: widget.initial?.password ?? '',
  );
  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final id =
        widget.initial?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    Navigator.of(context).pop(
      ServerConfig(
        id: id,
        kind: _kind,
        name: _nameController.text.trim(),
        host: _hostController.text.trim(),
        domain: _domainController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        accessToken: widget.initial?.accessToken ?? '',
        userId: widget.initial?.userId ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.initial == null ? '添加服务器' : '编辑服务器',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                SegmentedButton<ServerKind>(
                  segments: const [
                    ButtonSegment(
                      value: ServerKind.smb,
                      icon: Icon(Icons.folder_shared_outlined),
                      label: Text('SMB'),
                    ),
                    ButtonSegment(
                      value: ServerKind.emby,
                      icon: Icon(Icons.connected_tv_outlined),
                      label: Text('Emby'),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (selected) =>
                      setState(() => _kind = selected.first),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '例如 客厅 NAS',
                    prefixIcon: Icon(Icons.bookmark_outline),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _hostController,
                  decoration: InputDecoration(
                    labelText: _kind == ServerKind.emby ? 'Emby 地址' : 'NAS 地址',
                    hintText: _kind == ServerKind.emby
                        ? '例如 http://192.168.1.100:8096'
                        : '例如 192.168.1.100',
                    prefixIcon: const Icon(Icons.dns_outlined),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? '请输入 NAS 地址'
                      : null,
                ),
                const SizedBox(height: 12),
                if (_kind == ServerKind.smb) ...[
                  TextFormField(
                    controller: _domainController,
                    decoration: const InputDecoration(
                      labelText: '域',
                      hintText: '没有可留空',
                      prefixIcon: Icon(Icons.account_tree_outlined),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入用户名' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: '密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<ServerConfig?> showServerSwitcher(
  BuildContext context, {
  required String currentServerId,
}) {
  return showModalBottomSheet<ServerConfig>(
    context: context,
    showDragHandle: true,
    builder: (context) => ServerSwitcherSheet(currentServerId: currentServerId),
  );
}

class ServerSwitcherSheet extends StatefulWidget {
  const ServerSwitcherSheet({required this.currentServerId, super.key});

  final String currentServerId;

  @override
  State<ServerSwitcherSheet> createState() => _ServerSwitcherSheetState();
}

class _ServerSwitcherSheetState extends State<ServerSwitcherSheet> {
  late final Future<List<ServerConfig>> _serversFuture =
      ServerStore.loadServers();

  Future<void> _addServer() async {
    final server = await showServerEditor(context);
    if (server == null) {
      return;
    }
    await ServerStore.saveServer(server);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(server);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '切换服务器',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: '添加服务器',
                  icon: const Icon(Icons.add),
                  onPressed: _addServer,
                ),
              ],
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<ServerConfig>>(
              future: _serversFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 160,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final servers = snapshot.data ?? const <ServerConfig>[];
                return Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: servers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final server = servers[index];
                      final current = server.id == widget.currentServerId;
                      return ServerTile(
                        server: server,
                        isConnecting: false,
                        onTap: () => Navigator.of(context).pop(server),
                        trailing: current
                            ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : const Icon(Icons.chevron_right),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({required this.client, required this.server, super.key});

  final SmbConnect client;
  final ServerConfig server;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with WidgetsBindingObserver {
  final List<SmbFile> _stack = [];
  late SmbConnect _client;
  late LocalSmbStreamServer _streamServer;
  late Future<List<SmbFile>> _itemsFuture;
  bool _isSwitchingServer = false;
  bool _isDisposed = false;
  FileListViewMode _viewMode = FileListViewMode.detail;
  int _loadGeneration = 0;
  Future<void>? _reconnectFuture;

  SmbFile? get _currentFolder => _stack.isEmpty ? null : _stack.last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client;
    _streamServer = LocalSmbStreamServer(_client);
    _itemsFuture = _startItemsLoad();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _loadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_streamServer.close());
    unawaited(_client.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final route = ModalRoute.of(context);
    if (state == AppLifecycleState.resumed &&
        mounted &&
        (route?.isCurrent ?? true)) {
      _refresh(reconnect: true);
    }
  }

  Future<List<SmbFile>> _startItemsLoad({bool reconnect = false}) {
    final generation = ++_loadGeneration;
    return _guardedLoadItems(generation, reconnect: reconnect);
  }

  Future<List<SmbFile>> _guardedLoadItems(
    int generation, {
    required bool reconnect,
  }) async {
    try {
      if (reconnect) {
        await _reconnectClient();
      }
      final items = await _loadItems();
      if (_isStaleLoad(generation)) {
        return const <SmbFile>[];
      }
      return items;
    } catch (error, stackTrace) {
      Object displayedError = error;
      debugPrint(
        'Directory load failed: ${_friendlyError(error)}\n$stackTrace',
      );
      if (!reconnect && _shouldReconnectAfter(error)) {
        try {
          await _reconnectClient();
          final items = await _loadItems();
          if (_isStaleLoad(generation)) {
            return const <SmbFile>[];
          }
          return items;
        } catch (retryError, retryStackTrace) {
          debugPrint(
            'Directory reload after reconnect failed: '
            '${_friendlyError(retryError)}\n$retryStackTrace',
          );
          displayedError = retryError;
        }
      }
      if (_isStaleLoad(generation)) {
        return const <SmbFile>[];
      }
      throw DirectoryLoadException(_friendlyError(displayedError));
    }
  }

  bool _isStaleLoad(int generation) =>
      _isDisposed || generation != _loadGeneration;

  Future<List<SmbFile>> _loadItems() async {
    final folder = _currentFolder;
    final files = folder == null
        ? (await _client.listShares()).map(_shareToRootFolder).toList()
        : await _client.listFiles(await _freshFolder(folder));
    final visible = files.where(_isVisibleMediaEntry).toList()
      ..sort((a, b) {
        final typeCompare = _sortRank(a).compareTo(_sortRank(b));
        if (typeCompare != 0) {
          return typeCompare;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return visible;
  }

  Future<SmbFile> _freshFolder(SmbFile folder) async {
    final fresh = await _client.file(folder.path);
    if (_stack.isNotEmpty && _stack.last.path == folder.path) {
      _stack[_stack.length - 1] = fresh;
    }
    return fresh;
  }

  SmbFile _shareToRootFolder(SmbFile share) {
    final name = share.name;
    return SmbFile(
      '/$name',
      r'\',
      name,
      share.createTime,
      share.lastModified,
      share.lastAccess,
      share.attributes | _smbDirectoryAttribute,
      share.size,
      share.isExists,
    );
  }

  bool _isVisibleMediaEntry(SmbFile file) {
    if (file.name == SmbFile.NAME_DOT || file.name == SmbFile.NAME_DOT_DOT) {
      return false;
    }
    return file.isDirectory() || _isImage(file) || _isVideo(file);
  }

  int _sortRank(SmbFile file) {
    if (file.isDirectory()) {
      return 0;
    }
    if (_isImage(file)) {
      return 1;
    }
    return 2;
  }

  void _refresh({bool reconnect = false}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _itemsFuture = _startItemsLoad(reconnect: reconnect);
    });
  }

  Future<void> _reconnectClient() {
    _reconnectFuture ??= _doReconnectClient().whenComplete(() {
      _reconnectFuture = null;
    });
    return _reconnectFuture!;
  }

  Future<void> _doReconnectClient() async {
    final oldClient = _client;
    final oldStreamServer = _streamServer;
    try {
      await oldStreamServer.close();
    } catch (_) {
      // Ignore close failures from already-broken HTTP proxy sessions.
    }
    try {
      await oldClient.close();
    } catch (_) {
      // Ignore close failures from already-broken SMB sessions.
    }

    final client = await SmbConnect.connectAuth(
      host: widget.server.host.trim(),
      domain: widget.server.domain.trim(),
      username: widget.server.username.trim(),
      password: widget.server.password,
    );

    if (_isDisposed) {
      await client.close();
      return;
    }
    _client = client;
    _streamServer = LocalSmbStreamServer(_client);
  }

  bool _shouldReconnectAfter(Object error) {
    final message = _friendlyError(error).toLowerCase();
    return message.contains('streamsink is closed') ||
        message.contains('socket') ||
        message.contains('closed') ||
        message.contains('broken pipe') ||
        message.contains('connection reset') ||
        message.contains('connection refused') ||
        message.contains('timed out') ||
        message.contains('smbexception');
  }

  Future<bool> _goBack() async {
    if (_stack.isEmpty) {
      return true;
    }
    setState(() {
      _stack.removeLast();
      _itemsFuture = _startItemsLoad();
    });
    return false;
  }

  void _openFolder(SmbFile folder) {
    setState(() {
      _stack.add(folder);
      _itemsFuture = _startItemsLoad();
    });
  }

  Future<void> _switchServer() async {
    final selected = await showServerSwitcher(
      context,
      currentServerId: widget.server.id,
    );
    if (selected == null || selected.id == widget.server.id) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _isSwitchingServer = true);
    try {
      if (selected.kind == ServerKind.emby) {
        final client = await EmbyClient(selected).authenticate();
        await ServerStore.saveServer(client.config);
        await ServerStore.saveLastServerId(client.config.id);
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => EmbyHomePage(client: client)),
        );
        return;
      }

      final client = await SmbConnect.connectAuth(
        host: selected.host.trim(),
        domain: selected.domain.trim(),
        username: selected.username.trim(),
        password: selected.password,
      );
      await ServerStore.saveLastServerId(selected.id);
      if (!mounted) {
        await client.close();
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BrowserPage(client: client, server: selected),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isSwitchingServer = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切换服务器失败：${_friendlyError(error)}')),
      );
    }
  }

  Future<void> _openImage(SmbFile file, List<SmbFile> items) async {
    final images = items.where(_isImage).toList();
    final index = images.indexWhere((item) => item.path == file.path);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImageViewerPage(
          client: _client,
          images: images,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
    );
    _refresh();
  }

  Future<void> _openVideo(SmbFile file) async {
    final videos = (await _itemsFuture).where(_isVideo).toList();
    if (!mounted) {
      return;
    }
    final index = videos.indexWhere((item) => item.path == file.path);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(
          client: _client,
          streamServer: _streamServer,
          videos: videos,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
    );
    _refresh();
  }

  String _title() {
    final folder = _currentFolder;
    if (folder == null) {
      return '共享目录';
    }
    return folder.path;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stack.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          await _goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: _stack.isEmpty ? '切换服务器' : '返回上级',
            icon: _isSwitchingServer
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _stack.isEmpty ? Icons.storage_outlined : Icons.arrow_back,
                  ),
            onPressed: _isSwitchingServer
                ? null
                : _stack.isEmpty
                ? _switchServer
                : _goBack,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.server.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                _title(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            PopupMenuButton<FileListViewMode>(
              tooltip: '显示方式',
              icon: const Icon(Icons.view_module_outlined),
              initialValue: _viewMode,
              onSelected: (mode) => setState(() => _viewMode = mode),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: FileListViewMode.list,
                  child: ListTile(
                    leading: Icon(Icons.view_list_outlined),
                    title: Text('列表'),
                  ),
                ),
                PopupMenuItem(
                  value: FileListViewMode.detail,
                  child: ListTile(
                    leading: Icon(Icons.format_list_bulleted),
                    title: Text('详细列表'),
                  ),
                ),
                PopupMenuItem(
                  value: FileListViewMode.largeGrid,
                  child: ListTile(
                    leading: Icon(Icons.grid_view_outlined),
                    title: Text('大图标'),
                  ),
                ),
                PopupMenuItem(
                  value: FileListViewMode.mediumGrid,
                  child: ListTile(
                    leading: Icon(Icons.apps_outlined),
                    title: Text('中图标'),
                  ),
                ),
              ],
            ),
            if (_stack.isNotEmpty)
              IconButton(
                tooltip: '切换服务器',
                icon: const Icon(Icons.storage_outlined),
                onPressed: _isSwitchingServer ? null : _switchServer,
              ),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: () => _refresh(reconnect: true),
            ),
          ],
        ),
        body: FutureBuilder<List<SmbFile>>(
          future: _itemsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ErrorState(
                message: '读取目录失败：${_friendlyError(snapshot.error)}',
                onRetry: () => _refresh(reconnect: true),
              );
            }
            final items = snapshot.data ?? const <SmbFile>[];
            if (items.isEmpty) {
              return const EmptyState();
            }
            return _SmbFileList(
              items: items,
              mode: _viewMode,
              client: _client,
              streamServer: _streamServer,
              onOpen: (item) {
                if (item.isDirectory()) {
                  _openFolder(item);
                } else if (_isImage(item)) {
                  _openImage(item, items);
                } else {
                  _openVideo(item);
                }
              },
            );
          },
        ),
      ),
    );
  }
}

class _SmbFileList extends StatelessWidget {
  const _SmbFileList({
    required this.items,
    required this.mode,
    required this.client,
    required this.streamServer,
    required this.onOpen,
  });

  final List<SmbFile> items;
  final FileListViewMode mode;
  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final ValueChanged<SmbFile> onOpen;

  @override
  Widget build(BuildContext context) {
    if (mode == FileListViewMode.largeGrid ||
        mode == FileListViewMode.mediumGrid) {
      final crossAxisCount = mode == FileListViewMode.largeGrid ? 2 : 3;
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: mode == FileListViewMode.largeGrid ? 0.82 : 0.72,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => MediaFileTile(
          file: items[index],
          client: client,
          streamServer: streamServer,
          grid: true,
          onTap: () => onOpen(items[index]),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => MediaFileTile(
        file: items[index],
        client: client,
        streamServer: streamServer,
        compact: mode == FileListViewMode.list,
        onTap: () => onOpen(items[index]),
      ),
    );
  }
}

class EmbyClient {
  EmbyClient(this.config);

  final ServerConfig config;
  final HttpClient _httpClient = HttpClient();

  Uri get _baseUri {
    final raw = config.host.trim();
    return Uri.parse(raw.startsWith('http') ? raw : 'http://$raw');
  }

  Future<EmbyClient> authenticate() async {
    if (config.accessToken.isNotEmpty && config.userId.isNotEmpty) {
      return this;
    }
    final response = await _requestJson(
      'POST',
      '/Users/AuthenticateByName',
      body: {'Username': config.username.trim(), 'Pw': config.password},
      includeToken: false,
    );
    final user = response['User'] as Map<String, dynamic>? ?? {};
    final token = response['AccessToken'] as String? ?? '';
    final userId = user['Id'] as String? ?? '';
    if (token.isEmpty || userId.isEmpty) {
      throw const EmbyException('Emby 登录成功但没有返回用户令牌');
    }
    return EmbyClient(config.copyWith(accessToken: token, userId: userId));
  }

  Future<List<EmbyItem>> latest() async {
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items/Latest',
      query: {
        'Limit': '20',
        'Fields': 'PrimaryImageAspectRatio,MediaSources,Overview,DateCreated',
      },
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> libraries() async {
    final data = await _requestJson('GET', '/Users/${config.userId}/Views');
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Future<List<EmbyItem>> libraryItems(
    EmbyItem library,
    EmbyLibraryView view,
  ) async {
    if (view == EmbyLibraryView.genres) {
      final data = await _requestJson(
        'GET',
        '/Genres',
        query: {
          'UserId': config.userId,
          'ParentId': library.id,
          'SortBy': 'SortName',
        },
      );
      final list = data['Items'] as List<dynamic>? ?? [];
      return list.map(_itemFromJson).toList();
    }
    final query = {
      'ParentId': library.id,
      'Fields':
          'PrimaryImageAspectRatio,MediaSources,Overview,DateCreated,Genres',
      'SortBy': 'SortName',
    };
    if (view == EmbyLibraryView.programs) {
      query.addAll({
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Episode,Video,Series',
      });
    } else {
      query.addAll({'Recursive': 'false'});
    }
    final data = await _requestJson(
      'GET',
      '/Users/${config.userId}/Items',
      query: query,
    );
    final list = data['Items'] as List<dynamic>? ?? [];
    return list.map(_itemFromJson).toList();
  }

  Uri imageUri(EmbyItem item, {int maxHeight = 420}) {
    return _buildUri(
      '/Items/${item.id}/Images/Primary',
      query: {
        'maxHeight': '$maxHeight',
        'quality': '82',
        'api_key': config.accessToken,
      },
    );
  }

  Uri streamUri(EmbyItem item) {
    return _buildUri(
      '/Videos/${item.id}/stream',
      query: {'Static': 'true', 'api_key': config.accessToken},
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    bool includeToken = true,
  }) async {
    final request = await _httpClient.openUrl(
      method,
      _buildUri(path, query: query),
    );
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(
        'X-Emby-Authorization',
        'MediaBrowser Client="Media Player", Device="Flutter", DeviceId="media-player-flutter", Version="0.1.0"',
      );
    if (includeToken && config.accessToken.isNotEmpty) {
      request.headers.set('X-Emby-Token', config.accessToken);
    }
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw EmbyException('Emby 请求失败 ${response.statusCode}: $text');
    }
    if (text.trim().isEmpty) {
      return {};
    }
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is List<dynamic>) {
      return {'Items': decoded};
    }
    return {};
  }

  Uri _buildUri(String path, {Map<String, String> query = const {}}) {
    final base = _baseUri;
    final normalizedPath =
        '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}$path';
    return base.replace(
      path: normalizedPath,
      queryParameters: {...base.queryParameters, ...query},
    );
  }

  EmbyItem _itemFromJson(dynamic json) {
    final map = json as Map<String, dynamic>;
    return EmbyItem(
      id: map['Id'] as String? ?? '',
      name: map['Name'] as String? ?? '',
      type: map['Type'] as String? ?? '',
      overview: map['Overview'] as String? ?? '',
    );
  }
}

class EmbyItem {
  const EmbyItem({
    required this.id,
    required this.name,
    required this.type,
    required this.overview,
  });

  final String id;
  final String name;
  final String type;
  final String overview;

  bool get playable => const {'Movie', 'Episode', 'Video'}.contains(type);
}

class EmbyException implements Exception {
  const EmbyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class EmbyHomePage extends StatefulWidget {
  const EmbyHomePage({required this.client, super.key});

  final EmbyClient client;

  @override
  State<EmbyHomePage> createState() => _EmbyHomePageState();
}

class _EmbyHomePageState extends State<EmbyHomePage> {
  late Future<({List<EmbyItem> latest, List<EmbyItem> libraries})> _future =
      _load();

  Future<({List<EmbyItem> latest, List<EmbyItem> libraries})> _load() async {
    final latest = await widget.client.latest();
    final libraries = await widget.client.libraries();
    return (latest: latest, libraries: libraries);
  }

  Future<void> _switchServer() async {
    final selected = await showServerSwitcher(
      context,
      currentServerId: widget.client.config.id,
    );
    if (selected == null || !mounted) {
      return;
    }
    if (selected.kind == ServerKind.emby) {
      final client = await EmbyClient(selected).authenticate();
      await ServerStore.saveServer(client.config);
      await ServerStore.saveLastServerId(client.config.id);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => EmbyHomePage(client: client)),
      );
      return;
    }
    final client = await SmbConnect.connectAuth(
      host: selected.host.trim(),
      domain: selected.domain.trim(),
      username: selected.username.trim(),
      password: selected.password,
    );
    await ServerStore.saveLastServerId(selected.id);
    if (!mounted) {
      await client.close();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => BrowserPage(client: client, server: selected),
      ),
    );
  }

  void _refresh() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '切换服务器',
          icon: const Icon(Icons.storage_outlined),
          onPressed: _switchServer,
        ),
        title: Text(widget.client.config.displayName),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<({List<EmbyItem> latest, List<EmbyItem> libraries})>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '读取 Emby 失败：${_friendlyError(snapshot.error)}',
              onRetry: _refresh,
            );
          }
          final data = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              EmbyHorizontalSection(
                title: '最近播放',
                items: data.latest,
                client: widget.client,
                onTap: _openEmbyItem,
              ),
              const SizedBox(height: 18),
              EmbyHorizontalSection(
                title: '媒体库',
                items: data.libraries,
                client: widget.client,
                onTap: (item) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        EmbyLibraryPage(client: widget.client, library: item),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openEmbyItem(EmbyItem item) {
    if (!item.playable) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NetworkVideoPlayerPage(
          title: item.name,
          uri: widget.client.streamUri(item),
        ),
      ),
    );
  }
}

class EmbyHorizontalSection extends StatelessWidget {
  const EmbyHorizontalSection({
    required this.title,
    required this.items,
    required this.client,
    required this.onTap,
    super.key,
  });

  final String title;
  final List<EmbyItem> items;
  final EmbyClient client;
  final ValueChanged<EmbyItem> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        SizedBox(
          height: 206,
          child: items.isEmpty
              ? const Center(child: Text('暂无内容'))
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) => EmbyPosterCard(
                    item: items[index],
                    imageUri: client.imageUri(items[index]),
                    width: 126,
                    onTap: () => onTap(items[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

class EmbyLibraryPage extends StatefulWidget {
  const EmbyLibraryPage({
    required this.client,
    required this.library,
    super.key,
  });

  final EmbyClient client;
  final EmbyItem library;

  @override
  State<EmbyLibraryPage> createState() => _EmbyLibraryPageState();
}

class _EmbyLibraryPageState extends State<EmbyLibraryPage> {
  EmbyLibraryView _view = EmbyLibraryView.programs;
  late Future<List<EmbyItem>> _future = _load();

  Future<List<EmbyItem>> _load() =>
      widget.client.libraryItems(widget.library, _view);

  void _changeView(EmbyLibraryView view) {
    setState(() {
      _view = view;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.library.name)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: SegmentedButton<EmbyLibraryView>(
              segments: const [
                ButtonSegment(
                  value: EmbyLibraryView.programs,
                  label: Text('节目'),
                ),
                ButtonSegment(value: EmbyLibraryView.genres, label: Text('类型')),
                ButtonSegment(
                  value: EmbyLibraryView.folders,
                  label: Text('文件夹'),
                ),
              ],
              selected: {_view},
              onSelectionChanged: (selected) => _changeView(selected.first),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<EmbyItem>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return ErrorState(
                    message: '读取媒体库失败：${_friendlyError(snapshot.error)}',
                    onRetry: () => setState(() => _future = _load()),
                  );
                }
                final items = snapshot.data ?? const <EmbyItem>[];
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.65,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return EmbyPosterCard(
                      item: item,
                      imageUri: widget.client.imageUri(item),
                      onTap: () {
                        if (item.playable) {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => NetworkVideoPlayerPage(
                                title: item.name,
                                uri: widget.client.streamUri(item),
                              ),
                            ),
                          );
                        } else {
                          _changeView(EmbyLibraryView.programs);
                        }
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class EmbyPosterCard extends StatelessWidget {
  const EmbyPosterCard({
    required this.item,
    required this.imageUri,
    required this.onTap,
    this.width,
    super.key,
  });

  final EmbyItem item;
  final Uri imageUri;
  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Image.network(
                  imageUri.toString(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(
                      item.playable
                          ? Icons.movie_outlined
                          : Icons.video_library_outlined,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NetworkVideoPlayerPage extends StatefulWidget {
  const NetworkVideoPlayerPage({
    required this.title,
    required this.uri,
    super.key,
  });

  final String title;
  final Uri uri;

  @override
  State<NetworkVideoPlayerPage> createState() => _NetworkVideoPlayerPageState();
}

class _NetworkVideoPlayerPageState extends State<NetworkVideoPlayerPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  late final Future<void> _future = _player.open(
    Media(widget.uri.toString()),
    play: true,
  );

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const StreamingVideo();
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '视频加载失败：${_friendlyError(snapshot.error)}',
              onRetry: () => Navigator.of(context).pop(),
              dark: true,
            );
          }
          return Stack(
            children: [
              Positioned.fill(
                child: Video(controller: _controller, fit: BoxFit.contain),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: VideoTopBar(
                  title: widget.title,
                  isDeleting: false,
                  onBack: () => Navigator.of(context).pop(),
                  onDelete: null,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    required this.client,
    required this.images,
    required this.initialIndex,
    super.key,
  });

  final SmbConnect client;
  final List<SmbFile> images;
  final int initialIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final List<SmbFile> _images = List.of(widget.images);
  late final int _index = widget.initialIndex;
  late Future<Uint8List> _imageFuture = _loadImage();
  bool _isDeleting = false;

  SmbFile get _file => _images[_index];

  Future<Uint8List> _loadImage() async {
    final chunks = await widget.client.openRead(_file);
    final bytes = BytesBuilder();
    await for (final chunk in chunks) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _deleteCurrent() async {
    if (_isDeleting) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除图片'),
        content: Text('确定删除 “${_file.name}” 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    setState(() => _isDeleting = true);
    try {
      await widget.client.delete(_file);
      if (!mounted) {
        return;
      }
      if (_index + 1 >= _images.length) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _images.removeAt(_index);
        _imageFuture = _loadImage();
        _isDeleting = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isDeleting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：${_friendlyError(error)}')));
    }
  }

  void _showInfo() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_file.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              InfoRow(label: '路径', value: _file.path),
              InfoRow(label: '大小', value: _formatBytes(_file.size)),
              InfoRow(label: '创建时间', value: _formatDate(_file.createTime)),
              InfoRow(label: '修改时间', value: _formatDate(_file.lastModified)),
              InfoRow(label: '只读', value: _file.isReadonly() ? '是' : '否'),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: '返回文件列表',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '图片信息',
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfo,
          ),
          IconButton(
            tooltip: '删除',
            icon: _isDeleting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline),
            onPressed: _isDeleting ? null : _deleteCurrent,
          ),
        ],
      ),
      body: FutureBuilder<Uint8List>(
        future: _imageFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '图片加载失败：${_friendlyError(snapshot.error)}',
              onRetry: () => setState(() => _imageFuture = _loadImage()),
              dark: true,
            );
          }
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: SizedBox.expand(
              child: Center(
                child: Image.memory(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) {
                    return ErrorState(
                      message: '图片解码失败：${_friendlyError(error)}',
                      onRetry: () =>
                          setState(() => _imageFuture = _loadImage()),
                      dark: true,
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    required this.client,
    required this.streamServer,
    required this.videos,
    required this.initialIndex,
    super.key,
  });

  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final List<SmbFile> videos;
  final int initialIndex;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  late final List<SmbFile> _videos = List.of(widget.videos);
  late int _index = widget.initialIndex;
  Future<void>? _prepareFuture;
  bool _isDeleting = false;
  bool _isLandscape = false;
  bool _controlsVisible = true;
  VideoGestureMode _gestureMode = VideoGestureMode.none;
  Offset _gestureStart = Offset.zero;
  Duration _gestureStartPosition = Duration.zero;
  double _gestureStartBrightness = 0.5;
  double _gestureStartVolume = 0.5;
  String? _gestureText;

  SmbFile get _file => _videos[_index];

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    VolumeController.instance.showSystemUI = false;
    _prepareFuture = _prepareVideo();
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(ScreenBrightness.instance.resetApplicationScreenBrightness());
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _prepareVideo() async {
    final streamUri = await widget.streamServer.urlFor(_file);
    await _player.open(Media(streamUri.toString()), play: true);
  }

  Future<void> _openAt(int index) async {
    if (index < 0 || index >= _videos.length || index == _index) {
      return;
    }
    setState(() {
      _index = index;
      _prepareFuture = _prepareVideo();
    });
  }

  Future<void> _seekBy(int seconds) async {
    final next = _player.state.position + Duration(seconds: seconds);
    final duration = _player.state.duration;
    final clamped = Duration(
      milliseconds: next.inMilliseconds.clamp(
        0,
        duration.inMilliseconds <= 0
            ? next.inMilliseconds
            : duration.inMilliseconds,
      ),
    );
    await _player.seek(clamped);
  }

  Future<void> _toggleOrientation() async {
    _isLandscape = !_isLandscape;
    await SystemChrome.setPreferredOrientations(
      _isLandscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _onVideoPanStart(DragStartDetails details) async {
    _gestureStart = details.localPosition;
    _gestureStartPosition = _player.state.position;
    _gestureMode = VideoGestureMode.none;
    try {
      _gestureStartBrightness = await ScreenBrightness.instance.application;
    } catch (_) {
      _gestureStartBrightness = 0.5;
    }
    try {
      _gestureStartVolume = await VolumeController.instance.getVolume();
    } catch (_) {
      _gestureStartVolume = 0.5;
    }
  }

  Future<void> _onVideoPanUpdate(DragUpdateDetails details) async {
    final size = context.size;
    if (size == null) {
      return;
    }
    final delta = details.localPosition - _gestureStart;
    if (_gestureMode == VideoGestureMode.none) {
      if (delta.distance < 14) {
        return;
      }
      if (delta.dx.abs() >= delta.dy.abs()) {
        _gestureMode = VideoGestureMode.seek;
      } else if (_gestureStart.dx < size.width / 2) {
        _gestureMode = VideoGestureMode.brightness;
      } else {
        _gestureMode = VideoGestureMode.volume;
      }
    }

    switch (_gestureMode) {
      case VideoGestureMode.seek:
        final seconds = (delta.dx / 8).round();
        final target = _clampDuration(
          _gestureStartPosition + Duration(seconds: seconds),
        );
        await _player.seek(target);
        _setGestureText(
          '${seconds >= 0 ? '+' : ''}${seconds}s  ${_formatDuration(target)}',
        );
      case VideoGestureMode.brightness:
        final next = (_gestureStartBrightness - delta.dy / size.height).clamp(
          0.0,
          1.0,
        );
        await ScreenBrightness.instance.setApplicationScreenBrightness(next);
        _setGestureText('亮度 ${(next * 100).round()}%');
      case VideoGestureMode.volume:
        final next = (_gestureStartVolume - delta.dy / size.height).clamp(
          0.0,
          1.0,
        );
        await VolumeController.instance.setVolume(next);
        _setGestureText('音量 ${(next * 100).round()}%');
      case VideoGestureMode.none:
        break;
    }
  }

  void _onVideoPanEnd(DragEndDetails details) {
    _gestureMode = VideoGestureMode.none;
    Future<void>.delayed(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() => _gestureText = null);
      }
    });
  }

  Duration _clampDuration(Duration duration) {
    final total = _player.state.duration;
    final max = total.inMilliseconds <= 0
        ? duration.inMilliseconds
        : total.inMilliseconds;
    return Duration(milliseconds: duration.inMilliseconds.clamp(0, max));
  }

  void _setGestureText(String text) {
    if (mounted) {
      setState(() => _gestureText = text);
    }
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  Future<void> _deleteCurrent() async {
    if (_isDeleting) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除视频'),
        content: Text('确定删除 “${_file.name}” 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    setState(() => _isDeleting = true);
    try {
      await _player.pause();
      await widget.client.delete(_file);
      if (!mounted) {
        return;
      }
      if (_index + 1 >= _videos.length) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _videos.removeAt(_index);
        _prepareFuture = _prepareVideo();
        _isDeleting = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isDeleting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：${_friendlyError(error)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _prepareFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const StreamingVideo();
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '视频加载失败：${_friendlyError(snapshot.error)}',
              onRetry: () => setState(() => _prepareFuture = _prepareVideo()),
              dark: true,
            );
          }
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onPanStart: _onVideoPanStart,
                  onPanUpdate: _onVideoPanUpdate,
                  onPanEnd: _onVideoPanEnd,
                  child: Video(
                    controller: _controller,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),
                ),
              ),
              if (_gestureText != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _gestureText!,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
                ),
              if (_controlsVisible)
                Align(
                  alignment: Alignment.topCenter,
                  child: VideoTopBar(
                    title: _file.name,
                    isDeleting: _isDeleting,
                    onBack: () => Navigator.of(context).pop(),
                    onDelete: _isDeleting ? null : _deleteCurrent,
                  ),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: _controlsVisible
                    ? VideoControlBar(
                        player: _player,
                        canPrevious: _index > 0,
                        canNext: _index + 1 < _videos.length,
                        isLandscape: _isLandscape,
                        onPrevious: () => _openAt(_index - 1),
                        onNext: () => _openAt(_index + 1),
                        onBack15: () => _seekBy(-15),
                        onForward15: () => _seekBy(15),
                        onToggleOrientation: _toggleOrientation,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class VideoTopBar extends StatelessWidget {
  const VideoTopBar({
    required this.title,
    required this.isDeleting,
    required this.onBack,
    required this.onDelete,
    super.key,
  });

  final String title;
  final bool isDeleting;
  final VoidCallback onBack;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 18),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              color: Colors.white,
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: '删除',
              color: Colors.white,
              icon: isDeleting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class VideoControlBar extends StatelessWidget {
  const VideoControlBar({
    required this.player,
    required this.canPrevious,
    required this.canNext,
    required this.isLandscape,
    required this.onPrevious,
    required this.onNext,
    required this.onBack15,
    required this.onForward15,
    required this.onToggleOrientation,
    super.key,
  });

  final Player player;
  final bool canPrevious;
  final bool canNext;
  final bool isLandscape;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onBack15;
  final VoidCallback onForward15;
  final VoidCallback onToggleOrientation;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StreamBuilder<Duration>(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (context, positionSnapshot) {
                return StreamBuilder<Duration>(
                  stream: player.stream.duration,
                  initialData: player.state.duration,
                  builder: (context, durationSnapshot) {
                    final position = positionSnapshot.data ?? Duration.zero;
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final max = duration.inMilliseconds.toDouble();
                    final value = max <= 0
                        ? 0.0
                        : position.inMilliseconds
                              .clamp(0, duration.inMilliseconds)
                              .toDouble();
                    return Row(
                      children: [
                        Text(
                          _formatDuration(position),
                          style: const TextStyle(color: Colors.white),
                        ),
                        Expanded(
                          child: Slider(
                            value: value,
                            max: max <= 0 ? 1 : max,
                            onChanged: max <= 0
                                ? null
                                : (next) => player.seek(
                                    Duration(milliseconds: next.round()),
                                  ),
                          ),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: isLandscape ? '竖屏' : '横屏',
                  color: Colors.white,
                  icon: Icon(
                    isLandscape
                        ? Icons.stay_current_portrait
                        : Icons.stay_current_landscape,
                  ),
                  onPressed: onToggleOrientation,
                ),
                const Spacer(),
                IconButton(
                  tooltip: '上一部',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: canPrevious ? onPrevious : null,
                ),
                IconButton(
                  tooltip: '后退 15 秒',
                  color: Colors.white,
                  icon: const SecondsIcon(label: '15'),
                  onPressed: onBack15,
                ),
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (context, snapshot) {
                    final playing = snapshot.data ?? false;
                    return IconButton.filled(
                      tooltip: playing ? '暂停' : '播放',
                      iconSize: 32,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () => playing ? player.pause() : player.play(),
                    );
                  },
                ),
                IconButton(
                  tooltip: '前进 15 秒',
                  color: Colors.white,
                  icon: const SecondsIcon(label: '15', forward: true),
                  onPressed: onForward15,
                ),
                IconButton(
                  tooltip: '下一部',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_next),
                  onPressed: canNext ? onNext : null,
                ),
                const Spacer(),
                const SizedBox(width: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class LocalSmbStreamServer {
  LocalSmbStreamServer(this.client);

  final SmbConnect client;
  final Map<String, SmbFile> _files = {};
  HttpServer? _server;

  Future<Uri> urlFor(SmbFile file) async {
    await _ensureStarted();
    final token = base64Url
        .encode(
          utf8.encode('${file.path}:${DateTime.now().microsecondsSinceEpoch}'),
        )
        .replaceAll('=', '');
    _files[token] = file;
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
    await _server?.close(force: true);
    _server = null;
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

      final file = _files[segments[1]];
      if (file == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final total = file.size;
      final range = _parseRange(
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
        ..set(HttpHeaders.contentTypeHeader, _contentTypeFor(file.name))
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

      final stream = await client.openRead(
        file,
        range.start,
        range.endExclusive,
      );
      responseBodyStarted = true;
      await response.addStream(stream);
      await response.close();
    } catch (error) {
      if (!responseBodyStarted) {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      }
    }
  }
}

class ByteRange {
  const ByteRange(this.start, this.endInclusive);

  final int start;
  final int endInclusive;

  int get endExclusive => endInclusive + 1;
  int get length => endExclusive - start;
}

ByteRange? _parseRange(String? header, int total) {
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

Future<Uint8List> _readSmbBytes(SmbConnect client, SmbFile file) async {
  final chunks = await client.openRead(file);
  final bytes = BytesBuilder();
  await for (final chunk in chunks) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

String _contentTypeFor(String name) {
  switch (_extensionOf(name)) {
    case '.mp4':
    case '.m4v':
      return 'video/mp4';
    case '.mov':
      return 'video/quicktime';
    case '.webm':
      return 'video/webm';
    case '.mkv':
      return 'video/x-matroska';
    case '.avi':
      return 'video/x-msvideo';
    case '.ts':
    case '.m2ts':
      return 'video/mp2t';
    default:
      return 'application/octet-stream';
  }
}

class SecondsIcon extends StatelessWidget {
  const SecondsIcon({required this.label, this.forward = false, super.key});

  final String label;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(forward ? -1 : 1, 1, 1),
            child: const Icon(Icons.replay, size: 24),
          ),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class StreamingVideo extends StatelessWidget {
  const StreamingVideo({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            const Text('正在打开视频流...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('这里没有可显示的文件夹、图片或视频'));
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    required this.message,
    required this.onRetry,
    this.dark = false,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? Colors.white : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: color, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              style: TextStyle(color: color),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class DirectoryLoadException implements Exception {
  const DirectoryLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class InfoRow extends StatelessWidget {
  const InfoRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

bool _isImage(SmbFile file) =>
    file.isFile() && _imageExtensions.contains(_extensionOf(file.name));

bool _isVideo(SmbFile file) =>
    file.isFile() && _videoExtensions.contains(_extensionOf(file.name));

String _extensionOf(String name) {
  final index = name.lastIndexOf('.');
  if (index < 0) {
    return '';
  }
  return name.substring(index).toLowerCase();
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} ${units[unitIndex]}';
}

String _formatDate(int milliseconds) {
  if (milliseconds <= 0) {
    return '-';
  }
  return DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal().toString();
}

String _friendlyError(Object? error) {
  if (error == null) {
    return '未知错误';
  }
  try {
    final message = (error as dynamic).message;
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
  } catch (_) {
    // Some SDK errors do not expose a public message field.
  }
  final text = error.toString();
  if (text.startsWith('Instance of ')) {
    return error.runtimeType.toString();
  }
  return text;
}

String _formatDuration(Duration duration) {
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${two(minutes)}:${two(seconds)}';
  }
  return '${two(minutes)}:${two(seconds)}';
}
