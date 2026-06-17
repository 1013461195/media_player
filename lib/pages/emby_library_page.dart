import 'package:flutter/material.dart';

import '../emby_client.dart';
import '../models.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../players/network_video_player_page.dart';
import 'emby_series_page.dart';
import 'emby_home_page.dart';

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

  void _openItem(EmbyItem item) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.library.name)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
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
                    message: '读取媒体库失败：${friendlyError(snapshot.error)}',
                    onRetry: () => setState(() => _future = _load()),
                  );
                }
                final items = snapshot.data ?? const <EmbyItem>[];
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.62,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return EmbyPosterCard(
                      item: item,
                      imageUri: widget.client.imageUri(item),
                      onTap: () => _openItem(item),
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
