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
                  leading: _buildLeading(episode),
                  title: Text(episode.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 播放进度条
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: SizedBox(
                            height: 3,
                            child: episode.played
                                // 已播放完成：绿色满进度
                                ? const ColoredBox(color: appAccent)
                                // 未播放完：显示进度，未播放完留空白
                                : episode.hasProgress
                                    ? LinearProgressIndicator(
                                        value:
                                            (episode.playedPercentage ?? 0) / 100,
                                        backgroundColor: Colors.grey[300],
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                                appAccent),
                                      )
                                    : ColoredBox(color: Colors.grey[300]!),
                          ),
                        ),
                      ),
                      if (episode.overview.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            episode.overview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
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

  Widget _buildLeading(EmbyItem episode) {
    final position = episode.playbackPositionTicks;
    final total = episode.runTimeTicks;
    String? timeText;
    if (position > 0 && total != null && total > 0) {
      final posMin = position ~/ 600000000;
      final totalMin = total ~/ 600000000;
      timeText = '$posMin/$totalMin分钟';
    }
    return Stack(
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                episode.played
                    ? Icons.check_circle_outline
                    : Icons.play_circle_outline,
                color: episode.played ? appAccent : null,
              ),
              if (timeText != null)
                Text(
                  timeText,
                  style: const TextStyle(fontSize: 10),
                ),
            ],
          ),
        ),
        // 播放完成勾 - 右上角
        if (episode.played)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: appAccent,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check,
                color: Colors.white,
                size: 10,
              ),
            ),
          ),
      ],
    );
  }
}
