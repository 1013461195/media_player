import 'package:flutter/material.dart';

class SecondsIcon extends StatelessWidget {
  const SecondsIcon({required this.label, this.forward = false, super.key});

  final String label;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(forward ? -1 : 1, 1, 1),
            child: const Icon(Icons.replay, size: 24),
          ),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class StreamingVideo extends StatelessWidget {
  const StreamingVideo({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            const Text('正在打开视频流...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('这里没有可显示的文件夹、图片或视频'));
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    required this.message,
    required this.onRetry,
    this.dark = false,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? Colors.white : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: color, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              style: TextStyle(color: color),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
