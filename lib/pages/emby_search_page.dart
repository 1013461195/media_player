import 'dart:async';

import 'package:flutter/material.dart';

import '../emby_client.dart';
import '../models.dart';
import '../players/network_video_player_page.dart';
import '../utils.dart';
import '../widgets/common.dart';
import 'emby_detail_page.dart';
import 'emby_library_page.dart';

class EmbySearchPage extends StatefulWidget {
  const EmbySearchPage({required this.client, super.key});

  final EmbyClient client;

  @override
  State<EmbySearchPage> createState() => _EmbySearchPageState();
}

class _EmbySearchPageState extends State<EmbySearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  Future<List<EmbyItem>>? _future;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    setState(() => _query = query);
    if (query.isEmpty) {
      setState(() => _future = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _query != query) return;
      setState(() => _future = widget.client.search(query));
    });
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _query = '';
      _future = null;
    });
  }

  void _openItem(EmbyItem item) {
    if (item.isMovie || item.isSeries) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EmbyDetailPage(client: widget.client, item: item),
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
          builder: (_) => EmbyLibraryPage(client: widget.client, library: item),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (value) {
            _debounce?.cancel();
            final query = value.trim();
            if (query.isNotEmpty) {
              setState(() => _future = widget.client.search(query));
            }
          },
          decoration: InputDecoration(
            hintText: '搜索电影、电视剧、剧集',
            border: InputBorder.none,
            filled: false,
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空',
                    onPressed: _clear,
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final future = _future;
    if (_query.isEmpty) {
      return const _SearchPrompt(icon: Icons.search, text: '输入名称搜索 Emby 媒体库');
    }
    if (future == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return FutureBuilder<List<EmbyItem>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(
            message: '搜索失败：${friendlyError(snapshot.error)}',
            onRetry: () =>
                setState(() => _future = widget.client.search(_query)),
          );
        }
        final items = snapshot.data ?? const <EmbyItem>[];
        if (items.isEmpty) {
          return _SearchPrompt(icon: Icons.search_off, text: '没有找到“$_query”');
        }
        return GridView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 14,
            childAspectRatio: 0.62,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _SearchResultCard(
              item: item,
              imageUri: widget.client.imageUri(item),
              onTap: () => _openItem(item),
            );
          },
        );
      },
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.item,
    required this.imageUri,
    required this.onTap,
  });

  final EmbyItem item;
  final Uri imageUri;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                imageUri.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  color: appAccent.withValues(alpha: 0.12),
                  child: Icon(
                    item.isSeries ? Icons.tv : Icons.movie_outlined,
                    color: appAccent,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.1,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: appTextMuted),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: appTextMuted)),
        ],
      ),
    );
  }
}
