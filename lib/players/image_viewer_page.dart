import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:smb_connect/smb_connect.dart';

import '../utils.dart';
import '../widgets/common.dart';

class InfoRow extends StatelessWidget {
  const InfoRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    required this.client,
    required this.images,
    required this.initialIndex,
    super.key,
  });

  final SmbConnect client;
  final List<SmbFile> images;
  final int initialIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final List<SmbFile> _images = List.of(widget.images);
  late final int _index = widget.initialIndex;
  late Future<Uint8List> _imageFuture = _loadImage();
  bool _isDeleting = false;

  SmbFile get _file => _images[_index];

  Future<Uint8List> _loadImage() async {
    final chunks = await widget.client.openRead(_file);
    final bytes = BytesBuilder();
    await for (final chunk in chunks) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _deleteCurrent() async {
    if (_isDeleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除图片'),
        content: Text('确定删除 "${_file.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isDeleting = true);
    try {
      await widget.client.delete(_file);
      if (!mounted) return;
      if (_index + 1 >= _images.length) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _images.removeAt(_index);
        _imageFuture = _loadImage();
        _isDeleting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：${friendlyError(error)}')));
    }
  }

  void _showInfo() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_file.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              InfoRow(label: '路径', value: _file.path),
              InfoRow(label: '大小', value: formatBytes(_file.size)),
              InfoRow(label: '创建时间', value: formatDate(_file.createTime)),
              InfoRow(label: '修改时间', value: formatDate(_file.lastModified)),
              InfoRow(label: '只读', value: _file.isReadonly() ? '是' : '否'),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: '返回文件列表',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '图片信息',
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfo,
          ),
          IconButton(
            tooltip: '删除',
            icon: _isDeleting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline),
            onPressed: _isDeleting ? null : _deleteCurrent,
          ),
        ],
      ),
      body: FutureBuilder<Uint8List>(
        future: _imageFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '图片加载失败：${friendlyError(snapshot.error)}',
              onRetry: () => setState(() => _imageFuture = _loadImage()),
              dark: true,
            );
          }
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: SizedBox.expand(
              child: Center(
                child: Image.memory(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) {
                    return ErrorState(
                      message: '图片解码失败：${friendlyError(error)}',
                      onRetry: () =>
                          setState(() => _imageFuture = _loadImage()),
                      dark: true,
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
