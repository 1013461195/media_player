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
import 'emby_library_page.dart';
import 'emby_series_page.dart';
import 'server_home_page.dart';

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
    setState(() => _future = _load());
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
        AppCircleButton(icon: Icons.search, tooltip: '刷新', onPressed: _refresh),
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
      child: FutureBuilder<({List<EmbyItem> latest, List<EmbyItem> libraries})>(
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 0, 96),
            children: [
              const _EmbyTabs(),
              const SizedBox(height: 18),
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
                title: '继续观看',
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

  void _openEmbyItem(EmbyItem item) {
    if (item.playable) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkVideoPlayerPage(
            title: item.name,
            client: widget.client,
            item: item,
          ),
        ),
      );
    } else if (item.isSeries) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EmbySeriesPage(client: widget.client, series: item),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EmbyLibraryPage(client: widget.client, library: item),
        ),
      );
    }
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
                      if (item.playable) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => NetworkVideoPlayerPage(
                              title: item.name,
                              client: widget.client,
                              item: item,
                            ),
                          ),
                        );
                      } else if (item.isSeries) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EmbySeriesPage(
                              client: widget.client,
                              series: item,
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
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: landscape ? 22 : 42,
              child: Text(
                item.name,
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
  const _EmbyTabs();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '首页',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: appAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: 48,
              height: 3,
              decoration: BoxDecoration(
                color: appAccent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
        const SizedBox(width: 34),
        Text(
          '收藏',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: appTextPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
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
