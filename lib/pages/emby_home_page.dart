import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';

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
        MaterialPageRoute<void>(
            builder: (_) => EmbyHomePage(client: client)),
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
      body:
          FutureBuilder<({List<EmbyItem> latest, List<EmbyItem> libraries})>(
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              EmbyHorizontalSection(
                title: '最近播放',
                items: data.latest,
                client: widget.client,
                onTap: _openEmbyItem,
              ),
              const SizedBox(height: 18),
              ...data.libraries.map((lib) => Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: EmbyLibrarySection(
                      client: widget.client,
                      library: lib,
                    ),
                  )),
            ],
          );
        },
      ),
    );
  }

  void _openEmbyItem(EmbyItem item) {
    if (!item.playable) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NetworkVideoPlayerPage(
          title: item.name,
          client: widget.client,
          item: item,
        ),
      ),
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
          padding: const EdgeInsets.symmetric(horizontal: 0),
          child: Row(
            children: [
              Text(
                widget.library.name,
                style: Theme.of(context).textTheme.titleLarge,
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
                child: const Text('查看全部'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 206,
          child: FutureBuilder<List<EmbyItem>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child:
                      Text('加载失败: ${friendlyError(snapshot.error)}'),
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
                    width: 126,
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
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                    color:
                        Theme.of(context).colorScheme.primaryContainer,
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
