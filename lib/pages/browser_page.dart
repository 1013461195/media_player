import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';

import '../models.dart';
import '../smb_native_client.dart';
import '../smb_stream_server.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../players/video_player_page.dart';
import '../players/image_viewer_page.dart';
import '../server_store.dart';
import '../emby_client.dart';
import 'server_home_page.dart';
import 'emby_home_page.dart';

// ---------------------------------------------------------------------------
// Helpers (private to this file)
// ---------------------------------------------------------------------------

bool _isImageFile(SmbFile file) => file.isFile() && isImage(file.name);
bool _isVideoFile(SmbFile file) => file.isFile() && isVideo(file.name);

// ---------------------------------------------------------------------------
// BrowserPage
// ---------------------------------------------------------------------------

class BrowserPage extends StatefulWidget {
  const BrowserPage({required this.client, required this.server, super.key});

  final SmbConnect client;
  final ServerConfig server;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> with WidgetsBindingObserver {
  static const int _pageSize = 20;

  final List<SmbFile> _stack = [];
  late SmbConnect _client;
  late LocalSmbStreamServer _streamServer;
  final SmbNativeClient _nativeClient = SmbNativeClient();
  late Future<List<SmbFile>> _itemsFuture;
  bool _isSwitchingServer = false;
  bool _isDisposed = false;
  FileListViewMode _viewMode = FileListViewMode.detail;
  int _loadGeneration = 0;
  Future<void>? _reconnectFuture;

  // Pagination state
  List<SmbFile> _allItems = [];
  List<SmbFile> _displayItems = [];
  bool _hasMore = false;
  bool _isLoadingMore = false;

  SmbFile? get _currentFolder => _stack.isEmpty ? null : _stack.last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client;
    _streamServer = LocalSmbStreamServer(_client);
    _itemsFuture = _startItemsLoad();
    _connectNative();
  }

  Future<void> _connectNative() async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await _nativeClient.connect(
          host: widget.server.host,
          domain: widget.server.domain,
          username: widget.server.username,
          password: widget.server.password,
        );
        await _nativeClient.startHttpServer();
        debugPrint('Native SMB connected (attempt $attempt)');
        return;
      } catch (e) {
        debugPrint('Native SMB connect failed (attempt $attempt): $e');
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _loadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_streamServer.close());
    unawaited(_client.close());
    unawaited(_nativeClient.stopHttpServer());
    unawaited(_nativeClient.disconnect());
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
        'Directory load failed: ${friendlyError(error)}\n$stackTrace',
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
            '${friendlyError(retryError)}\n$retryStackTrace',
          );
          displayedError = retryError;
        }
      }
      if (_isStaleLoad(generation)) {
        return const <SmbFile>[];
      }
      throw DirectoryLoadException(friendlyError(displayedError));
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
      share.attributes | smbDirectoryAttribute,
      share.size,
      share.isExists,
    );
  }

  bool _isVisibleMediaEntry(SmbFile file) {
    if (file.name == SmbFile.NAME_DOT || file.name == SmbFile.NAME_DOT_DOT) {
      return false;
    }
    return file.isDirectory() || _isImageFile(file) || _isVideoFile(file);
  }

  int _sortRank(SmbFile file) {
    if (file.isDirectory()) {
      return 0;
    }
    if (_isImageFile(file)) {
      return 1;
    }
    return 2;
  }

  void _refresh({bool reconnect = false}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _allItems = [];
      _displayItems = [];
      _hasMore = false;
      _isLoadingMore = false;
      _itemsFuture = _startItemsLoad(reconnect: reconnect);
    });
  }

  void _loadMore() {
    if (_isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    final nextEnd = (_displayItems.length + _pageSize).clamp(0, _allItems.length);
    setState(() {
      _displayItems = _allItems.sublist(0, nextEnd);
      _hasMore = nextEnd < _allItems.length;
      _isLoadingMore = false;
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
    await _nativeClient.disconnect();
    await _connectNative();
  }

  bool _shouldReconnectAfter(Object error) {
    final message = friendlyError(error).toLowerCase();
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
      _allItems = [];
      _displayItems = [];
      _hasMore = false;
      _isLoadingMore = false;
      _itemsFuture = _startItemsLoad();
    });
    return false;
  }

  void _openFolder(SmbFile folder) {
    setState(() {
      _stack.add(folder);
      _allItems = [];
      _displayItems = [];
      _hasMore = false;
      _isLoadingMore = false;
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
          MaterialPageRoute<void>(
            builder: (_) => EmbyHomePage(client: client),
          ),
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
        SnackBar(content: Text('切换服务器失败：${friendlyError(error)}')),
      );
    }
  }

  Future<void> _openImage(SmbFile file, List<SmbFile> items) async {
    final images = items.where(_isImageFile).toList();
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
    // Use _allItems (full list) so prev/next works across all videos, not just displayed page
    final videos = _allItems.where(_isVideoFile).toList();
    if (!mounted) return;
    final index = videos.indexWhere((item) => item.path == file.path);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(
          client: _client,
          streamServer: _streamServer,
          nativeClient: _nativeClient.isConnected ? _nativeClient : null,
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
                message: '读取目录失败：${friendlyError(snapshot.error)}',
                onRetry: () => _refresh(reconnect: true),
              );
            }
            final items = snapshot.data ?? const <SmbFile>[];
            if (items.isEmpty) {
              return const EmptyState();
            }
            // Populate pagination state on first load or refresh
            if (_displayItems.isEmpty && items.isNotEmpty) {
              _allItems = items;
              _displayItems = items.length > _pageSize
                  ? items.sublist(0, _pageSize)
                  : items;
              _hasMore = items.length > _pageSize;
            }
            return _SmbFileList(
              items: _displayItems,
              hasMore: _hasMore,
              isLoadingMore: _isLoadingMore,
              onLoadMore: _loadMore,
              mode: _viewMode,
              client: _client,
              streamServer: _streamServer,
              onOpen: (item) {
                if (item.isDirectory()) {
                  _openFolder(item);
                } else if (_isImageFile(item)) {
                  _openImage(item, _allItems);
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

// ---------------------------------------------------------------------------
// _SmbFileList
// ---------------------------------------------------------------------------

class _SmbFileList extends StatefulWidget {
  const _SmbFileList({
    required this.items,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
    required this.mode,
    required this.client,
    required this.streamServer,
    required this.onOpen,
  });

  final List<SmbFile> items;
  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;
  final FileListViewMode mode;
  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final ValueChanged<SmbFile> onOpen;

  @override
  State<_SmbFileList> createState() => _SmbFileListState();
}

class _SmbFileListState extends State<_SmbFileList> {
  ScrollController? _scrollController;

  @override
  void dispose() {
    _scrollController?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final controller = _scrollController;
    if (controller == null) return;
    // Load more when within 400px of the bottom
    if (controller.position.pixels >= controller.position.maxScrollExtent - 400) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final mode = widget.mode;
    final totalItems = items.length + (widget.hasMore || widget.isLoadingMore ? 1 : 0);

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
        itemCount: totalItems,
        itemBuilder: (context, index) {
          if (index >= items.length) {
            // Loading indicator at the end
            widget.onLoadMore();
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return MediaFileTile(
            file: items[index],
            client: widget.client,
            streamServer: widget.streamServer,
            grid: true,
            thumbnailDelay: Duration(milliseconds: index * 80),
            onTap: () => widget.onOpen(items[index]),
          );
        },
      );
    }

    return ListView.separated(
      controller: _scrollController ??= ScrollController()..addListener(_onScroll),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
      itemCount: totalItems,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          // Loading indicator at the end
          widget.onLoadMore();
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return MediaFileTile(
          file: items[index],
          client: widget.client,
          streamServer: widget.streamServer,
          compact: mode == FileListViewMode.list,
          thumbnailDelay: Duration(milliseconds: index * 80),
          onTap: () => widget.onOpen(items[index]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// MediaFileTile
// ---------------------------------------------------------------------------

class MediaFileTile extends StatelessWidget {
  const MediaFileTile({
    required this.file,
    required this.onTap,
    required this.client,
    required this.streamServer,
    this.compact = false,
    this.grid = false,
    this.thumbnailDelay = Duration.zero,
    super.key,
  });

  final SmbFile file;
  final VoidCallback onTap;
  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final bool compact;
  final bool grid;
  final Duration thumbnailDelay;

  @override
  Widget build(BuildContext context) {
    final isFolder = file.isDirectory();
    final image = _isImageFile(file);
    final colorScheme = Theme.of(context).colorScheme;
    final icon = isFolder
        ? Icons.folder_outlined
        : image
        ? Icons.image_outlined
        : Icons.movie_outlined;
    final color = isFolder
        ? colorScheme.primary
        : image
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
                  delay: thumbnailDelay,
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
                  delay: thumbnailDelay,
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
                            : '${image ? '图片' : '视频'} · ${formatBytes(file.size)}',
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

// ---------------------------------------------------------------------------
// SmbThumbnail
// ---------------------------------------------------------------------------

class SmbThumbnail extends StatefulWidget {
  const SmbThumbnail({
    required this.file,
    required this.client,
    required this.streamServer,
    required this.fallbackIcon,
    required this.color,
    this.delay = Duration.zero,
    super.key,
  });

  /// Delay before starting thumbnail load (for staggering).
  final Duration delay;

  final SmbFile file;
  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final IconData fallbackIcon;
  final Color color;

  @override
  State<SmbThumbnail> createState() => _SmbThumbnailState();
}

class _SmbThumbnailState extends State<SmbThumbnail> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    final file = widget.file;
    if (file.isDirectory()) return;

    // Stagger thumbnail loading so the list renders first
    if (widget.delay != Duration.zero) {
      await Future<void>.delayed(widget.delay);
    }
    if (_disposed) return;

    final cacheKey = _isVideoFile(file) ? 'v:${file.name}' : file.name;
    final cached = thumbnailCache.get(cacheKey);
    if (cached != null) {
      if (!_disposed) setState(() => _bytes = cached);
      return;
    }

    if (!_disposed) setState(() => _loading = true);

    try {
      Uint8List? result;
      if (_isImageFile(file)) {
        final raw = await readSmbBytes(widget.client, file);
        if (_disposed) return;
        result = await downscaleImage(raw, 256);
      } else if (_isVideoFile(file)) {
        final uri = await widget.streamServer.urlFor(file);
        if (_disposed) return;
        await videoThumbnailSemaphore.acquire();
        try {
          result = await VideoThumbnail.thumbnailData(
            video: uri.toString(),
            imageFormat: ImageFormat.JPEG,
            maxWidth: 320,
            quality: 70,
          );
        } finally {
          videoThumbnailSemaphore.release();
        }
      }
      if (_disposed || result == null) return;
      thumbnailCache.put(cacheKey, result);
      setState(() {
        _bytes = result;
        _loading = false;
      });
    } catch (_) {
      if (!_disposed) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.file.isDirectory()) {
      return _fallback();
    }
    if (_bytes != null) {
      if (_isVideoFile(widget.file)) {
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(_bytes!, fit: BoxFit.cover),
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
      return Image.memory(
        _bytes!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(),
      );
    }
    return _fallback(loading: _loading);
  }

  Widget _fallback({bool loading = false}) {
    return Container(
      color: widget.color.withValues(alpha: 0.13),
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(widget.fallbackIcon, color: widget.color),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Thumbnail cache & helpers (private to this file)
// ---------------------------------------------------------------------------

class ThumbnailCache {
  static const int _maxSize = 200;
  final Map<String, Uint8List> _cache = {};

  Uint8List? get(String key) {
    final value = _cache.remove(key);
    if (value != null) _cache[key] = value; // move to end (most recently used)
    return value;
  }

  void put(String key, Uint8List bytes) {
    _cache.remove(key);
    _cache[key] = bytes;
    if (_cache.length > _maxSize) {
      _cache.remove(_cache.keys.first);
    }
  }
}

final thumbnailCache = ThumbnailCache();

class Semaphore {
  Semaphore(this._maxConcurrent);
  final int _maxConcurrent;
  int _current = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() async {
    if (_current < _maxConcurrent) {
      _current++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _current--;
    }
  }
}

final videoThumbnailSemaphore = Semaphore(3);

Future<Uint8List> downscaleImage(Uint8List bytes, int targetWidth) async {
  final codec = await ui.instantiateImageCodec(bytes,
      targetWidth: targetWidth, targetHeight: targetWidth);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  codec.dispose();
  return data!.buffer.asUint8List();
}
