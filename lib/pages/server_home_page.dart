import 'dart:async';

import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';

import '../emby_client.dart';
import '../models.dart';
import '../server_store.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../app_navigation.dart';
import 'browser_page.dart';
import 'emby_home_page.dart';

// ---------------------------------------------------------------------------
// ServerHomePage
// ---------------------------------------------------------------------------

class ServerHomePage extends StatefulWidget {
  const ServerHomePage({this.autoConnect = true, super.key});

  final bool autoConnect;

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
    if (!widget.autoConnect) {
      return servers;
    }
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
      ).showSnackBar(SnackBar(content: Text('连接失败：${friendlyError(error)}')));
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

  Future<void> _editServer(ServerConfig server) async {
    final updated = await showServerEditor(
      context,
      initial: server,
      onDelete: () async {
        await ServerStore.deleteServer(server.id);
        _reloadServers();
      },
    );
    if (updated == null) {
      return;
    }
    await ServerStore.saveServer(updated);
    _reloadServers();
  }

  @override
  Widget build(BuildContext context) {
    return AppPageShell(
      title: '服务管理',
      actions: [
        AppCircleButton(
          icon: Icons.more_horiz,
          tooltip: '添加服务器',
          onPressed: _addServer,
        ),
      ],
      bottomNavigationBar: AppTabBar(
        active: AppTab.servers,
        onChanged: (tab) => openAppTab(context, tab, active: AppTab.servers),
      ),
      child: FutureBuilder<List<ServerConfig>>(
        future: _serversFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final servers = snapshot.data ?? const <ServerConfig>[];
          final fileServers = servers
              .where((server) => server.category == ServerCategory.fileService)
              .toList();
          final mediaServers = servers
              .where((server) => server.category == ServerCategory.mediaServer)
              .toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (fileServers.isNotEmpty) ...[
                const AppSectionLabel('文件服务'),
                _ServerGroup(
                  servers: fileServers,
                  connectingId: _connectingId,
                  onConnect: _connect,
                  onEdit: _editServer,
                ),
              ],
              if (mediaServers.isNotEmpty) ...[
                const AppSectionLabel('媒体服务器'),
                _ServerGroup(
                  servers: mediaServers,
                  connectingId: _connectingId,
                  onConnect: _connect,
                  onEdit: _editServer,
                ),
              ],
              const AppSectionLabel('添加文件服务'),
              AppGroupedList(
                children: [
                  ServerKindTile(
                    icon: Icons.folder_rounded,
                    label: 'SMB',
                    color: const Color(0xffffc532),
                    onTap: () async {
                      final server = await showServerEditor(
                        context,
                        defaultKind: ServerKind.smb,
                      );
                      if (server == null) return;
                      await ServerStore.saveServer(server);
                      _reloadServers();
                    },
                  ),
                ],
              ),
              const AppSectionLabel('添加媒体服务器'),
              AppGroupedList(
                children: [
                  ServerKindTile(
                    icon: Icons.play_arrow_rounded,
                    label: 'Emby',
                    color: const Color(0xff35bd4c),
                    onTap: () async {
                      final server = await showServerEditor(
                        context,
                        defaultKind: ServerKind.emby,
                      );
                      if (server == null) return;
                      await ServerStore.saveServer(server);
                      _reloadServers();
                    },
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ServerGroup extends StatelessWidget {
  const _ServerGroup({
    required this.servers,
    required this.connectingId,
    required this.onConnect,
    required this.onEdit,
  });

  final List<ServerConfig> servers;
  final String? connectingId;
  final ValueChanged<ServerConfig> onConnect;
  final ValueChanged<ServerConfig> onEdit;

  @override
  Widget build(BuildContext context) {
    return AppGroupedList(
      children: [
        for (var index = 0; index < servers.length; index++) ...[
          ServerTile(
            server: servers[index],
            isConnecting: connectingId == servers[index].id,
            onTap: () => onConnect(servers[index]),
            onEdit: () => onEdit(servers[index]),
          ),
          if (index != servers.length - 1) const AppListDivider(),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// EmptyServerState
// ---------------------------------------------------------------------------

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
          const Text('添加服务后会自动记住，下次打开直接进入上次使用的服务'),
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

class ServerKindTile extends StatelessWidget {
  const ServerKindTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xff57575d),
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xffc9c9cd), size: 26),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ServerTile
// ---------------------------------------------------------------------------

class ServerTile extends StatelessWidget {
  const ServerTile({
    required this.server,
    required this.isConnecting,
    required this.onTap,
    this.onEdit,
    this.highlighted = false,
    super.key,
  });

  final ServerConfig server;
  final bool isConnecting;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final iconColor = server.kind == ServerKind.emby
        ? const Color(0xff35bd4c)
        : const Color(0xff2777ec);
    return Material(
      color: highlighted ? appAccent.withValues(alpha: 0.08) : Colors.white,
      child: InkWell(
        onTap: isConnecting ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: iconColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  server.kind == ServerKind.emby
                      ? Icons.play_arrow_rounded
                      : Icons.folder_shared_rounded,
                  color: Colors.white,
                  size: 25,
                ),
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: appTextPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${server.kind.protocolLabel} - ${server.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: appTextMuted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              if (isConnecting)
                const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (onEdit != null)
                IconButton(
                  icon: const Icon(Icons.more_horiz, size: 24),
                  color: const Color(0xffb9b9bd),
                  tooltip: '修改',
                  onPressed: onEdit,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// showServerEditor / ServerEditorSheet
// ---------------------------------------------------------------------------

Future<ServerConfig?> showServerEditor(
  BuildContext context, {
  ServerConfig? initial,
  ServerKind defaultKind = ServerKind.smb,
  VoidCallback? onDelete,
}) {
  return showModalBottomSheet<ServerConfig>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.9,
    ),
    builder: (context) {
      final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
      final colorScheme = Theme.of(context).colorScheme;
      return AnimatedPadding(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Material(
          color: colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: ServerEditorSheet(
            initial: initial,
            defaultKind: defaultKind,
            onDelete: onDelete,
          ),
        ),
      );
    },
  );
}

class ServerEditorSheet extends StatefulWidget {
  const ServerEditorSheet({
    this.initial,
    this.defaultKind = ServerKind.smb,
    this.onDelete,
    super.key,
  });

  final ServerConfig? initial;
  final ServerKind defaultKind;
  final VoidCallback? onDelete;

  @override
  State<ServerEditorSheet> createState() => _ServerEditorSheetState();
}

class _ServerEditorSheetState extends State<ServerEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late ServerKind _kind = widget.initial?.kind ?? widget.defaultKind;
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

  // Emby: protocol / ip / port
  late String _embyProtocol;
  late final TextEditingController _embyIpController;
  late final TextEditingController _embyPortController;

  @override
  void initState() {
    super.initState();
    final raw = widget.initial?.host.trim() ?? '';
    if (raw.startsWith('https')) {
      _embyProtocol = 'https';
    } else {
      _embyProtocol = 'http';
    }
    String ip = '';
    String port = '';
    if (raw.isNotEmpty) {
      final withoutScheme = raw.replaceFirst(RegExp(r'^https?://'), '');
      final parts = withoutScheme.split(':');
      ip = parts[0];
      if (parts.length > 1) {
        port = parts[1];
      }
    }
    _embyIpController = TextEditingController(text: ip);
    _embyPortController = TextEditingController(text: port);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _embyIpController.dispose();
    _embyPortController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final id =
        widget.initial?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    final String host;
    if (_kind == ServerKind.emby) {
      final ip = _embyIpController.text.trim();
      final port = _embyPortController.text.trim();
      host = port.isEmpty
          ? '$_embyProtocol://$ip'
          : '$_embyProtocol://$ip:$port';
    } else {
      host = _hostController.text.trim();
    }
    Navigator.of(context).pop(
      ServerConfig(
        id: id,
        kind: _kind,
        name: _nameController.text.trim(),
        host: host,
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
    return Form(
      key: _formKey,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        children: [
          Column(
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
                    label: Text('文件 · SMB'),
                  ),
                  ButtonSegment(
                    value: ServerKind.emby,
                    icon: Icon(Icons.connected_tv_outlined),
                    label: Text('媒体 · Emby'),
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
              if (_kind == ServerKind.emby) ...[
                Row(
                  children: [
                    DropdownButton<String>(
                      value: _embyProtocol,
                      items: const [
                        DropdownMenuItem(value: 'http', child: Text('http')),
                        DropdownMenuItem(value: 'https', child: Text('https')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _embyProtocol = v);
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _embyIpController,
                        decoration: const InputDecoration(
                          labelText: 'IP 地址',
                          hintText: '例如 192.168.1.100',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '请输入 IP 地址'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: TextFormField(
                        controller: _embyPortController,
                        decoration: const InputDecoration(
                          labelText: '端口',
                          hintText: '8096',
                          prefixIcon: Icon(Icons.tag_outlined),
                        ),
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                  ],
                ),
              ] else ...[
                TextFormField(
                  controller: _hostController,
                  decoration: const InputDecoration(
                    labelText: 'NAS 地址',
                    hintText: '例如 192.168.1.100',
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? '请输入 NAS 地址'
                      : null,
                ),
              ],
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
              if (widget.onDelete != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('删除服务器'),
                          content: Text(
                            '确定要删除「${widget.initial!.displayName}」吗？',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              style: TextButton.styleFrom(
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                              ),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && context.mounted) {
                        widget.onDelete!();
                        Navigator.of(context).pop();
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除服务器'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// showServerSwitcher / ServerSwitcherSheet
// ---------------------------------------------------------------------------

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
  late Future<List<ServerConfig>> _serversFuture = ServerStore.loadServers();

  void _reloadServers() {
    setState(() {
      _serversFuture = ServerStore.loadServers();
    });
  }

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

  Future<void> _editServer(ServerConfig server) async {
    final updated = await showServerEditor(
      context,
      initial: server,
      onDelete: () async {
        await ServerStore.deleteServer(server.id);
        _reloadServers();
      },
    );
    if (updated == null) {
      return;
    }
    await ServerStore.saveServer(updated);
    _reloadServers();
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
                final fileServers = servers
                    .where(
                      (server) => server.category == ServerCategory.fileService,
                    )
                    .toList();
                final mediaServers = servers
                    .where(
                      (server) => server.category == ServerCategory.mediaServer,
                    )
                    .toList();
                return Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (fileServers.isNotEmpty) ...[
                        const _SwitcherSectionLabel('文件服务'),
                        _SwitcherServerGroup(
                          servers: fileServers,
                          currentServerId: widget.currentServerId,
                          onSelect: (server) =>
                              Navigator.of(context).pop(server),
                          onEdit: _editServer,
                        ),
                      ],
                      if (mediaServers.isNotEmpty) ...[
                        const _SwitcherSectionLabel('媒体服务器'),
                        _SwitcherServerGroup(
                          servers: mediaServers,
                          currentServerId: widget.currentServerId,
                          onSelect: (server) =>
                              Navigator.of(context).pop(server),
                          onEdit: _editServer,
                        ),
                      ],
                    ],
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

class _SwitcherSectionLabel extends StatelessWidget {
  const _SwitcherSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(color: appTextMuted),
      ),
    );
  }
}

class _SwitcherServerGroup extends StatelessWidget {
  const _SwitcherServerGroup({
    required this.servers,
    required this.currentServerId,
    required this.onSelect,
    required this.onEdit,
  });

  final List<ServerConfig> servers;
  final String currentServerId;
  final ValueChanged<ServerConfig> onSelect;
  final ValueChanged<ServerConfig> onEdit;

  @override
  Widget build(BuildContext context) {
    return AppGroupedList(
      margin: EdgeInsets.zero,
      children: [
        for (var index = 0; index < servers.length; index++) ...[
          ServerTile(
            server: servers[index],
            isConnecting: false,
            onTap: () => onSelect(servers[index]),
            onEdit: () => onEdit(servers[index]),
            highlighted: servers[index].id == currentServerId,
          ),
          if (index != servers.length - 1) const AppListDivider(),
        ],
      ],
    );
  }
}
