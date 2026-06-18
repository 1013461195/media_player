import 'package:flutter/material.dart';

import '../emby_client.dart';
import '../models.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../players/network_video_player_page.dart';

class EmbyDetailPage extends StatefulWidget {
  const EmbyDetailPage({required this.client, required this.item, super.key});

  final EmbyClient client;
  final EmbyItem item;

  @override
  State<EmbyDetailPage> createState() => _EmbyDetailPageState();
}

class _EmbyDetailPageState extends State<EmbyDetailPage> {
  final ScrollController _scrollController = ScrollController();
  late Future<_EmbyDetailData> _future = _load();
  EmbyItem? _selectedSeason;
  EmbyItem? _selectedEpisode;
  final Map<String, bool> _favoriteOverrides = {};
  final Set<String> _updatingFavorites = {};

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<_EmbyDetailData> _load() async {
    final detail = await widget.client.itemDetails(widget.item);
    if (!detail.isSeries) {
      return _EmbyDetailData(detail: detail);
    }

    final seasons = await widget.client.seriesSeasons(detail);
    final selected = _selectedSeason ?? seasons.firstOrNull;
    final episodes = selected == null
        ? const <EmbyItem>[]
        : await widget.client.seasonEpisodes(detail, selected);
    return _EmbyDetailData(
      detail: detail,
      seasons: seasons,
      selectedSeason: selected,
      episodes: episodes,
    );
  }

  void _selectSeason(EmbyItem season) {
    setState(() {
      _selectedSeason = season;
      _selectedEpisode = null;
      _future = _load();
    });
  }

  void _selectEpisode(EmbyItem episode) {
    setState(() => _selectedEpisode = episode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        330,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _play(EmbyItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NetworkVideoPlayerPage(
          title: item.seriesName.isEmpty
              ? item.name
              : '${item.seriesName} - ${item.name}',
          client: widget.client,
          item: item,
        ),
      ),
    );
  }

  Future<void> _toggleFavorite(EmbyItem item) async {
    if (_updatingFavorites.contains(item.id)) return;
    final current = _favoriteOverrides[item.id] ?? item.isFavorite;
    final next = !current;
    setState(() {
      _updatingFavorites.add(item.id);
      _favoriteOverrides[item.id] = next;
    });
    try {
      await widget.client.setFavorite(item, next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _favoriteOverrides[item.id] = current);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('收藏失败：${friendlyError(error)}')));
    } finally {
      if (mounted) {
        setState(() => _updatingFavorites.remove(item.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: FutureBuilder<_EmbyDetailData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '读取详情失败：${friendlyError(snapshot.error)}',
              onRetry: () => setState(() => _future = _load()),
            );
          }

          final data = snapshot.data!;
          final detail = data.detail;
          final selectedEpisode = data.episodes
              .where((episode) => episode.id == _selectedEpisode?.id)
              .firstOrNull;
          final displayItem = selectedEpisode ?? detail;
          final playTarget =
              selectedEpisode ??
              (detail.playable ? detail : data.episodes.firstOrNull);
          final mediaItem = playTarget ?? detail;
          final displayGenres = displayItem.genres.isNotEmpty
              ? displayItem.genres
              : detail.genres;
          final displayRating = displayItem.officialRating.isNotEmpty
              ? displayItem.officialRating
              : detail.officialRating;
          final displayPeople = displayItem.people.isNotEmpty
              ? displayItem.people
              : detail.people;
          final favoriteTarget = selectedEpisode ?? detail;
          final favorite =
              _favoriteOverrides[favoriteTarget.id] ??
              favoriteTarget.isFavorite;
          final updatingFavorite = _updatingFavorites.contains(
            favoriteTarget.id,
          );
          return CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: _DetailHero(client: widget.client, item: displayItem),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
                sliver: SliverList.list(
                  children: [
                    Text(
                      _displayTitle(detail, selectedEpisode),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: appTextPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _metadata(displayItem, mediaItem),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: appTextMuted),
                    ),
                    if (displayGenres.isNotEmpty ||
                        displayRating.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        [
                          ...displayGenres,
                          if (displayRating.isNotEmpty) displayRating,
                        ].join(' · '),
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: appTextMuted),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: playTarget == null
                                ? null
                                : () => _play(playTarget),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('播放'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xff08a66c),
                              minimumSize: const Size.fromHeight(52),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          tooltip: favorite ? '取消收藏' : '收藏',
                          onPressed: updatingFavorite
                              ? null
                              : () => _toggleFavorite(favoriteTarget),
                          icon: updatingFavorite
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(favorite ? Icons.star : Icons.star_border),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: '标记',
                          onPressed: () {},
                          icon: const Icon(Icons.outlined_flag),
                        ),
                      ],
                    ),
                    if (displayItem.overview.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      const _SectionTitle('简介'),
                      const SizedBox(height: 8),
                      Text(
                        displayItem.overview,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          height: 1.55,
                          color: appTextPrimary,
                        ),
                      ),
                    ],
                    if (detail.isSeries && data.seasons.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      _SeasonHeader(
                        seasons: data.seasons,
                        selected: data.selectedSeason!,
                        onSelected: _selectSeason,
                      ),
                      const SizedBox(height: 12),
                      _EpisodeList(
                        client: widget.client,
                        episodes: data.episodes,
                        selectedEpisodeId: selectedEpisode?.id,
                        onTap: _selectEpisode,
                      ),
                    ],
                    if (displayPeople.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      const _SectionTitle('演职人员'),
                      const SizedBox(height: 12),
                      _PeopleList(client: widget.client, people: displayPeople),
                    ],
                    if (mediaItem.mediaSources.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      const _SectionTitle('音视频字幕信息'),
                      const SizedBox(height: 12),
                      _MediaSourceSection(source: mediaItem.mediaSources.first),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DetailHero extends StatelessWidget {
  const _DetailHero({required this.client, required this.item});

  final EmbyClient client;
  final EmbyItem item;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 380,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            client.backdropUri(item).toString(),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Image.network(
              client.imageUri(item, maxHeight: 800).toString(),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(color: Colors.black12),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.55, 1],
                colors: [Colors.black45, Colors.transparent, Colors.white],
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton.filledTonal(
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton.filledTonal(
                  tooltip: '更多',
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({
    required this.seasons,
    required this.selected,
    required this.onSelected,
  });

  final List<EmbyItem> seasons;
  final EmbyItem selected;
  final ValueChanged<EmbyItem> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        DropdownButton<EmbyItem>(
          value: selected,
          underline: const SizedBox.shrink(),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: appTextPrimary,
            fontWeight: FontWeight.w600,
          ),
          items: seasons
              .map(
                (season) =>
                    DropdownMenuItem(value: season, child: Text(season.name)),
              )
              .toList(),
          onChanged: (season) {
            if (season != null) onSelected(season);
          },
        ),
        const Spacer(),
        Text('${selected.name} · 选集', style: const TextStyle(color: appAccent)),
      ],
    );
  }
}

class _EpisodeList extends StatelessWidget {
  const _EpisodeList({
    required this.client,
    required this.episodes,
    required this.selectedEpisodeId,
    required this.onTap,
  });

  final EmbyClient client;
  final List<EmbyItem> episodes;
  final String? selectedEpisodeId;
  final ValueChanged<EmbyItem> onTap;

  @override
  Widget build(BuildContext context) {
    if (episodes.isEmpty) return const Text('暂无剧集');
    return SizedBox(
      height: 148,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final episode = episodes[index];
          final selected = episode.id == selectedEpisodeId;
          return SizedBox(
            width: 210,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onTap(episode),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: EdgeInsets.all(selected ? 3 : 0),
                      decoration: BoxDecoration(
                        color: selected ? appAccent : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(
                          client.imageUri(episode).toString(),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, _, _) => Container(
                            color: appAccent.withValues(alpha: 0.1),
                            child: const Center(
                              child: Icon(Icons.play_circle_outline),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${episode.indexNumber ?? index + 1}. ${episode.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? appAccent : appTextPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PeopleList extends StatelessWidget {
  const _PeopleList({required this.client, required this.people});

  final EmbyClient client;
  final List<EmbyPerson> people;

  @override
  Widget build(BuildContext context) {
    final visible = people.take(12).toList();
    return SizedBox(
      height: 126,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final person = visible[index];
          return SizedBox(
            width: 76,
            child: Column(
              children: [
                CircleAvatar(
                  radius: 34,
                  backgroundColor: Colors.black12,
                  backgroundImage: person.id.isEmpty
                      ? null
                      : NetworkImage(client.personImageUri(person).toString()),
                  child: person.id.isEmpty
                      ? const Icon(Icons.person_outline)
                      : null,
                ),
                const SizedBox(height: 6),
                Text(
                  person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  person.role,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: appTextMuted),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MediaSourceSection extends StatelessWidget {
  const _MediaSourceSection({required this.source});

  final EmbyMediaSource source;

  @override
  Widget build(BuildContext context) {
    final streams = source.streams
        .where((stream) => stream.type == 'Video' || stream.type == 'Audio')
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 212,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: streams.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) =>
                _StreamInfoCard(stream: streams[index]),
          ),
        ),
        if (source.path.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xfff2f2f4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              [
                source.path,
                [
                  if (source.size != null) formatBytes(source.size!),
                  if (source.container.isNotEmpty)
                    source.container.toUpperCase(),
                ].join(' · '),
              ].where((line) => line.isNotEmpty).join('\n'),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: appTextMuted, height: 1.4),
            ),
          ),
        ],
      ],
    );
  }
}

class _StreamInfoCard extends StatelessWidget {
  const _StreamInfoCard({required this.stream});

  final EmbyMediaStream stream;

  @override
  Widget build(BuildContext context) {
    final isVideo = stream.type == 'Video';
    final lines = isVideo
        ? [
            '标题: ${stream.displayTitle}',
            '编码: ${stream.codec}',
            '配置文件: ${stream.profile}',
            if (stream.width != null && stream.height != null)
              '分辨率: ${stream.width}x${stream.height}',
            if (stream.bitRate != null)
              '比特率: ${(stream.bitRate! / 1000).round()} kbps',
            if (stream.videoRange.isNotEmpty) '视频范围: ${stream.videoRange}',
          ]
        : [
            '标题: ${stream.displayTitle}',
            '语言: ${stream.language}',
            '编码: ${stream.codec}',
            if (stream.channelLayout.isNotEmpty)
              '声道布局: ${stream.channelLayout}',
            if (stream.channels != null) '声道数: ${stream.channels}',
            if (stream.sampleRate != null) '采样率: ${stream.sampleRate} Hz',
            if (stream.bitRate != null)
              '比特率: ${(stream.bitRate! / 1000).round()} kbps',
          ];
    return Container(
      width: 250,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfff2f2f4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isVideo ? Icons.videocam : Icons.music_note, size: 20),
              const SizedBox(width: 6),
              Text(
                isVideo ? '视频' : '音频',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: appTextMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: appTextPrimary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _EmbyDetailData {
  const _EmbyDetailData({
    required this.detail,
    this.seasons = const [],
    this.selectedSeason,
    this.episodes = const [],
  });

  final EmbyItem detail;
  final List<EmbyItem> seasons;
  final EmbyItem? selectedSeason;
  final List<EmbyItem> episodes;
}

String _displayTitle(EmbyItem series, EmbyItem? episode) {
  if (episode == null) return series.name;
  final episodeLabel = episode.indexNumber == null
      ? '剧集'
      : '第 ${episode.indexNumber} 集';
  final episodeName = episode.name.trim();
  return episodeName.isEmpty || episodeName == episodeLabel
      ? '${series.name} $episodeLabel'
      : '${series.name} $episodeLabel - $episodeName';
}

String _metadata(EmbyItem detail, EmbyItem mediaItem) {
  final source = mediaItem.mediaSources.firstOrNull;
  final video = source?.streams
      .where((stream) => stream.type == 'Video')
      .firstOrNull;
  return [
    if (detail.communityRating != null)
      '★${detail.communityRating!.toStringAsFixed(1)}',
    if (detail.productionYear != null) '${detail.productionYear}',
    if (detail.runtime != null) _formatRuntime(detail.runtime!),
    if (video?.height != null) '${video!.height}p',
    if (video?.videoRange.isNotEmpty == true) video!.videoRange,
    if (video?.codec.isNotEmpty == true) video!.codec.toUpperCase(),
  ].join('  ');
}

String _formatRuntime(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return '$minutes分钟';
  return '$hours小时$minutes分钟';
}
