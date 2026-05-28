import 'package:flutter/material.dart';

import '../emby_client.dart';
import '../models.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../players/network_video_player_page.dart';

class EmbySeriesPage extends StatefulWidget {
  const EmbySeriesPage({
    required this.client,
    required this.series,
    super.key,
  });

  final EmbyClient client;
  final EmbyItem series;

  @override
  State<EmbySeriesPage> createState() => _EmbySeriesPageState();
}

class _EmbySeriesPageState extends State<EmbySeriesPage> {
  late Future<List<EmbyItem>> _future = _load();

  Future<List<EmbyItem>> _load() =>
      widget.client.seriesEpisodes(widget.series);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.series.name)),
      body: FutureBuilder<List<EmbyItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '读取剧集失败：${friendlyError(snapshot.error)}',
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final episodes = snapshot.data ?? const <EmbyItem>[];
          if (episodes.isEmpty) {
            return const Center(child: Text('暂无剧集'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(14),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(episode.name),
                  subtitle: episode.overview.isNotEmpty
                      ? Text(
                          episode.overview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NetworkVideoPlayerPage(
                          title:
                              '${widget.series.name} - ${episode.name}',
                          client: widget.client,
                          item: episode,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
