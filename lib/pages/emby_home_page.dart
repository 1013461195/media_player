import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';

import '../app_navigation.dart';
import '../emby_client.dart';
import '../models.dart';
import '../server_store.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../players/network_video_player_page.dart';
import 'browser_page.dart';
import 'emby_detail_page.dart';
import 'emby_library_page.dart';
import 'emby_search_page.dart';
import 'server_home_page.dart';

class EmbyHomePage extends StatefulWidget {
  const EmbyHomePage({required this.client, super.key});

  final EmbyClient client;

  @override
  State<EmbyHomePage> createState() => _EmbyHomePageState();
}

class _EmbyHomePageState extends State<EmbyHomePage> {
  late Future<({List<EmbyItem> resume, List<EmbyItem> latest, List<EmbyItem> libraries})> _future =
      _load();
  Future<List<EmbyItem>>? _favoritesFuture;
  bool _showFavorites = false;

  Future<({List<EmbyItem> resume, List<EmbyItem> latest, List<EmbyItem> libraries})> _load() async {
    final resume = await widget.client.resumeItems();
    final latest = await widget.client.latest();
    final libraries = await widget.client.libraries();
    return (resume: resume, latest: latest, libraries: libraries);
  }

  Future<void> _switchServer() async {
    final selected = await showServerSwitcher(
      context,
      currentServerId: widget.client.config.id,
    );
    if (selected == null || !mounted) return;
    if (selected.kind == ServerKind.emby) {
      final client = await EmbyClient(selected).authenticate();
      await ServerStore.saveServer(client.config);
      await ServerStore.saveLastServerId(client.config.id);
      if (!mounted) return;
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
    setState(() {
      if (_showFavorites) {
        _favoritesFuture = widget.client.favorites();
      } else {
        _future = _load();
      }
    });
  }

  void _selectSection(bool favorites) {
    if (_showFavorites == favorites) return;
    setState(() {
      _showFavorites = favorites;
      if (favorites) {
        _favoritesFuture = widget.client.favorites();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppPageShell(
      title: widget.client.config.displayName,
      backgroundColor: Colors.white,
      leading: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 1,
        shadowColor: Colors.black12,
        child: IconButton(
          tooltip: '切换服务器',
          icon: const Icon(Icons.play_arrow_rounded, color: appAccent),
          onPressed: _switchServer,
        ),
      ),
      actions: [
        AppCircleButton(
          icon: Icons.search,
          tooltip: '搜索',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => EmbySearchPage(client: widget.client),
            ),
          ),
        ),
        AppCircleButton(
          icon: Icons.more_horiz,
          tooltip: '切换服务器',
          onPressed: _switchServer,
        ),
      ],
      bottomNavigationBar: AppTabBar(
        active: AppTab.media,
        onChanged: (tab) => openAppTab(
          context,
          tab,
          active: AppTab.media,
          currentServer: widget.client.config,
        ),
      ),
      child: FutureBuilder<({List<EmbyItem> resume, List<EmbyItem> latest, List<EmbyItem> libraries})>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '读取 Emby 失败：${friendlyError(snapshot.error)}',
              onRetry: _refresh,
            );
          }
          final data = snapshot.data!;
          if (_showFavorites) {
            return _FavoritesBody(
              future: _favoritesFuture ??= widget.client.favorites(),
              client: widget.client,
              onSelectSection: _selectSection,
              onOpen: _openEmbyItem,
              onRetry: _refresh,
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 0, 96),
            children: [
              _EmbyTabs(showFavorites: false, onChanged: _selectSection),
              const SizedBox(height: 18),
              if (data.resume.isNotEmpty) ...[
                EmbyHorizontalSection(
                  title: '继续播放',
                  items: data.resume,
                  client: widget.client,
                  onTap: _openEmbyItem,
                  continueLayout: true,
                ),
                const SizedBox(height: 20),
              ],
              if (data.libraries.isNotEmpty) ...[
                Text(
                  '我的媒体',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: appTextPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 112,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 20),
                    itemCount: data.libraries.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final library = data.libraries[index];
                      return _LibraryPreviewCard(
                        library: library,
                        client: widget.client,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EmbyLibraryPage(
                              client: widget.client,
                              library: library,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
              ],
              EmbyHorizontalSection(
                title: '最近添加',
                items: data.latest,
                client: widget.client,
                onTap: _openEmbyItem,
                continueLayout: true,
              ),
              const SizedBox(height: 12),
              ...data.libraries.map(
                (lib) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: EmbyLibrarySection(
                    client: widget.client,
                    library: lib,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openEmbyItem(EmbyItem item) async {
    if (item.isMovie || item.isSeries) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EmbyDetailPage(client: widget.client, item: item),
        ),
      );
    } else if (item.playable) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkVideoPlayerPage(
            title: item.name,
            client: widget.client,
            item: item,
          ),
        ),
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EmbyLibraryPage(client: widget.client, library: item),
        ),
      );
    }
    if (mounted && _showFavorites) {
      setState(() => _favoritesFuture = widget.client.favorites());
    }
  }
}

class _FavoritesBody extends StatelessWidget {
  const _FavoritesBody({
    required this.future,
    required this.client,
    required this.onSelectSection,
    required this.onOpen,
    required this.onRetry,
  });

  final Future<List<EmbyItem>> future;
  final EmbyClient client;
  final ValueChanged<bool> onSelectSection;
  final ValueChanged<EmbyItem> onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: _EmbyTabs(showFavorites: true, onChanged: onSelectSection),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: FutureBuilder<List<EmbyItem>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return ErrorState(
                  message: '读取收藏失败：${friendlyError(snapshot.error)}',
                  onRetry: onRetry,
                );
              }
              final items = snapshot.data ?? const <EmbyItem>[];
              if (items.isEmpty) {
                return const Center(child: Text('还没有收藏内容'));
              }
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.62,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return EmbyPosterCard(
                    item: item,
                    imageUri: client.imageUri(item),
                    onTap: () => onOpen(item),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class EmbyLibrarySection extends StatefulWidget {
  const EmbyLibrarySection({
    required this.client,
    required this.library,
    super.key,
  });

  final EmbyClient client;
  final EmbyItem library;

  @override
  State<EmbyLibrarySection> createState() => _EmbyLibrarySectionState();
}

class _EmbyLibrarySectionState extends State<EmbyLibrarySection> {
  late final Future<List<EmbyItem>> _future = _load();

  Future<List<EmbyItem>> _load() =>
      widget.client.libraryItems(widget.library, EmbyLibraryView.programs);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Row(
            children: [
              Text(
                widget.library.name,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: appTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EmbyLibraryPage(
                      client: widget.client,
                      library: widget.library,
                    ),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('查看全部'),
                    SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 22),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 218,
          child: FutureBuilder<List<EmbyItem>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text('加载失败: ${friendlyError(snapshot.error)}'),
                );
              }
              final items = snapshot.data ?? const <EmbyItem>[];
              if (items.isEmpty) {
                return const Center(child: Text('暂无内容'));
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return EmbyPosterCard(
                    item: item,
                    imageUri: widget.client.imageUri(item),
                    width: 112,
                    onTap: () {
                      if (item.isMovie || item.isSeries) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EmbyDetailPage(
                              client: widget.client,
                              item: item,
                            ),
                          ),
                        );
                      } else if (item.playable) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => NetworkVideoPlayerPage(
                              title: item.name,
                              client: widget.client,
                              item: item,
                            ),
                          ),
                        );
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EmbyLibraryPage(
                              client: widget.client,
                              library: item,
                            ),
                          ),
                        );
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class EmbyHorizontalSection extends StatelessWidget {
  const EmbyHorizontalSection({
    required this.title,
    required this.items,
    required this.client,
    required this.onTap,
    this.continueLayout = false,
    super.key,
  });

  final String title;
  final List<EmbyItem> items;
  final EmbyClient client;
  final ValueChanged<EmbyItem> onTap;
  final bool continueLayout;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: continueLayout ? 148 : 218,
          child: items.isEmpty
              ? const Center(child: Text('暂无内容'))
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(right: 20),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) => EmbyPosterCard(
                    item: items[index],
                    imageUri: client.imageUri(items[index]),
                    width: continueLayout ? 196 : 112,
                    landscape: continueLayout,
                    onTap: () => onTap(items[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

class EmbyPosterCard extends StatelessWidget {
  const EmbyPosterCard({
    required this.item,
    required this.imageUri,
    required this.onTap,
    this.width,
    this.landscape = false,
    super.key,
  });

  final EmbyItem item;
  final Uri imageUri;
  final VoidCallback onTap;
  final double? width;
  final bool landscape;

  String _getItemDisplayName(EmbyItem item) {
    // 如果是剧集，显示 "电视剧名称 - 第X集" 或 "电视剧名称 - 剧集名称"
    if (item.isEpisode) {
      final episodeName = item.name.trim();
      String episodeLabel;

      // 判断剧集名称是否为纯数字或为空
      if (episodeName.isEmpty || RegExp(r'^\d+$').hasMatch(episodeName)) {
        final number = item.indexNumber ?? 0;
        episodeLabel = '第$number集';
      } else {
        episodeLabel = episodeName;
      }

      // 如果有系列名称，显示 "系列名 - 剧集标识"
      if (item.seriesName.isNotEmpty) {
        return '${item.seriesName} - $episodeLabel';
      }
      return episodeLabel;
    }

    // 其他类型直接返回名称
    return item.name;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      imageUri.toString(),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: appAccent.withValues(alpha: 0.12),
                        child: Icon(
                          item.playable
                              ? Icons.movie_outlined
                              : Icons.video_library_outlined,
                          color: appAccent,
                        ),
                      ),
                    ),
                    if (landscape)
                      Center(
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.78),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: appAccent,
                            size: 34,
                          ),
                        ),
                      ),
                    // 播放完成勾 - 右上角
                    if (item.played)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                            color: appAccent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                      ),
                    // 播放进度条 - 底部
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SizedBox(
                        height: 3,
                        child: item.played
                            // 已播放完成：绿色满进度
                            ? const ColoredBox(color: appAccent)
                            // 未播放完：显示进度，未播放完留空白
                            : item.hasProgress
                                ? LinearProgressIndicator(
                                    value: (item.playedPercentage ?? 0) / 100,
                                    backgroundColor:
                                        Colors.white.withValues(alpha: 0.3),
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                            appAccent),
                                  )
                                : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: landscape ? 22 : 42,
              child: Text(
                _getItemDisplayName(item),
                maxLines: landscape ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: appTextPrimary,
                  fontWeight: FontWeight.w500,
                  height: 1.12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmbyTabs extends StatelessWidget {
  const _EmbyTabs({required this.showFavorites, required this.onChanged});

  final bool showFavorites;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _EmbyTabButton(
          label: '首页',
          selected: !showFavorites,
          onTap: () => onChanged(false),
        ),
        const SizedBox(width: 34),
        _EmbyTabButton(
          label: '收藏',
          selected: showFavorites,
          onTap: () => onChanged(true),
        ),
      ],
    );
  }
}

class _EmbyTabButton extends StatelessWidget {
  const _EmbyTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? appAccent : appTextPrimary;
    return InkWell(
      onTap: selected ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 48,
              height: 3,
              decoration: BoxDecoration(
                color: selected ? appAccent : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryPreviewCard extends StatelessWidget {
  const _LibraryPreviewCard({
    required this.library,
    required this.client,
    required this.onTap,
  });

  final EmbyItem library;
  final EmbyClient client;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      client.imageUri(library).toString(),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xffe9fbf5), Color(0xffffffff)],
                          ),
                        ),
                        child: const Icon(
                          Icons.video_library_outlined,
                          color: appAccent,
                          size: 34,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        height: 42,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0),
                              Colors.white.withValues(alpha: 0.88),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              library.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: appTextPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
