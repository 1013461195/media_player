import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:smb_connect/smb_connect.dart';
import 'package:volume_controller/volume_controller.dart';

import '../emby_client.dart';
import '../models.dart';
import '../smb_native_client.dart';
import '../smb_stream_server.dart';
import '../utils.dart';
import '../widgets/common.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    required this.client,
    required this.streamServer,
    required this.videos,
    required this.initialIndex,
    this.nativeClient,
    super.key,
  });

  final SmbConnect client;
  final LocalSmbStreamServer streamServer;
  final SmbNativeClient? nativeClient;
  final List<SmbFile> videos;
  final int initialIndex;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  late final List<SmbFile> _videos = List.of(widget.videos);
  late int _index = widget.initialIndex;
  Future<void>? _prepareFuture;
  bool _isDeleting = false;
  bool _isLandscape = false;
  bool _controlsVisible = true;
  VideoGestureMode _gestureMode = VideoGestureMode.none;
  Offset _gestureStart = Offset.zero;
  Duration _gestureStartPosition = Duration.zero;
  double _gestureStartBrightness = 0.5;
  double _gestureStartVolume = 0.5;
  String? _gestureText;
  final Set<int> _dolbyCheckedIndices = {};

  SmbFile get _file => _videos[_index];

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    VolumeController.instance.showSystemUI = false;
    _prepareFuture = _prepareVideo();
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(ScreenBrightness.instance.resetApplicationScreenBrightness());
    unawaited(_player.dispose());
    super.dispose();
  }

  bool _isDolbyVisionContent(String name) {
    final lowerName = name.toLowerCase();
    return lowerName.contains('dolby') ||
        lowerName.contains('.dv.') ||
        lowerName.contains('.dovi.') ||
        lowerName.contains('dolbyvision');
  }

  Future<void> _checkDolbyVisionSupport() async {
    if (_dolbyCheckedIndices.contains(_index)) return;
    _dolbyCheckedIndices.add(_index);

    if (!_isDolbyVisionContent(_file.name)) return;

    final isSupported = await HdrDetector.isDolbyVisionSupported();
    if (!isSupported && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前设备暂不支持杜比视界，已为您切换至标准色彩模式'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _prepareVideo() async {
    final native = widget.nativeClient;
    final String uri;
    if (native != null && native.isConnected) {
      // Native HTTP server uses SMBJ — much faster than Dart smb_connect.
      uri = await native.getHttpUrl(_file.path, _file.name);
    } else {
      uri = (await widget.streamServer.urlFor(_file)).toString();
    }
    debugPrint('[SMB Player] Opening: $uri');
    await _checkDolbyVisionSupport();
    await _player.open(Media(uri), play: true);
  }

  Future<void> _openAt(int index) async {
    if (index < 0 || index >= _videos.length || index == _index) {
      return;
    }
    setState(() {
      _index = index;
      _prepareFuture = _prepareVideo();
    });
  }

  Future<void> _seekBy(int seconds) async {
    final next = _player.state.position + Duration(seconds: seconds);
    final duration = _player.state.duration;
    final clamped = Duration(
      milliseconds: next.inMilliseconds.clamp(
        0,
        duration.inMilliseconds <= 0
            ? next.inMilliseconds
            : duration.inMilliseconds,
      ),
    );
    await _player.seek(clamped);
  }

  Future<void> _toggleOrientation() async {
    _isLandscape = !_isLandscape;
    await SystemChrome.setPreferredOrientations(
      _isLandscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _onVideoPanStart(DragStartDetails details) async {
    _gestureStart = details.localPosition;
    _gestureStartPosition = _player.state.position;
    _gestureMode = VideoGestureMode.none;
    try {
      _gestureStartBrightness = await ScreenBrightness.instance.application;
    } catch (_) {
      _gestureStartBrightness = 0.5;
    }
    try {
      _gestureStartVolume = await VolumeController.instance.getVolume();
    } catch (_) {
      _gestureStartVolume = 0.5;
    }
  }

  Future<void> _onVideoPanUpdate(DragUpdateDetails details) async {
    final size = context.size;
    if (size == null) {
      return;
    }
    final delta = details.localPosition - _gestureStart;
    if (_gestureMode == VideoGestureMode.none) {
      if (delta.distance < 14) {
        return;
      }
      if (delta.dx.abs() >= delta.dy.abs()) {
        _gestureMode = VideoGestureMode.seek;
      } else if (_gestureStart.dx < size.width / 2) {
        _gestureMode = VideoGestureMode.brightness;
      } else {
        _gestureMode = VideoGestureMode.volume;
      }
    }

    switch (_gestureMode) {
      case VideoGestureMode.seek:
        final seconds = (delta.dx / 8).round();
        final target = _clampDuration(
          _gestureStartPosition + Duration(seconds: seconds),
        );
        await _player.seek(target);
        _setGestureText(
          '${seconds >= 0 ? '+' : ''}${seconds}s  ${formatDuration(target)}',
        );
      case VideoGestureMode.brightness:
        final next = (_gestureStartBrightness - delta.dy / size.height).clamp(
          0.0,
          1.0,
        );
        await ScreenBrightness.instance.setApplicationScreenBrightness(next);
        _setGestureText('亮度 ${(next * 100).round()}%');
      case VideoGestureMode.volume:
        final next = (_gestureStartVolume - delta.dy / size.height).clamp(
          0.0,
          1.0,
        );
        await VolumeController.instance.setVolume(next);
        _setGestureText('音量 ${(next * 100).round()}%');
      case VideoGestureMode.none:
        break;
    }
  }

  void _onVideoPanEnd(DragEndDetails details) {
    _gestureMode = VideoGestureMode.none;
    Future<void>.delayed(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() => _gestureText = null);
      }
    });
  }

  Duration _clampDuration(Duration duration) {
    final total = _player.state.duration;
    final max = total.inMilliseconds <= 0
        ? duration.inMilliseconds
        : total.inMilliseconds;
    return Duration(milliseconds: duration.inMilliseconds.clamp(0, max));
  }

  void _setGestureText(String text) {
    if (mounted) {
      setState(() => _gestureText = text);
    }
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  Future<void> _deleteCurrent() async {
    if (_isDeleting) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除视频'),
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
    if (confirmed != true) {
      return;
    }

    setState(() => _isDeleting = true);
    try {
      await _player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final native = widget.nativeClient;
      if (native != null && native.isConnected) {
        try {
          await native.deleteFile(_file.path);
        } catch (e) {
          debugPrint('[SMB Player] Native delete failed, falling back: $e');
          await widget.client.delete(_file);
        }
      } else {
        await widget.client.delete(_file);
      }
      if (!mounted) {
        return;
      }
      if (_index + 1 >= _videos.length) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _videos.removeAt(_index);
        _prepareFuture = _prepareVideo();
        _isDeleting = false;
      });
    } catch (error, stack) {
      debugPrint('[SMB Player] Delete failed: $error');
      debugPrint('[SMB Player] Stack trace: $stack');
      if (!mounted) {
        return;
      }
      setState(() => _isDeleting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：${friendlyError(error)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _prepareFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const StreamingVideo();
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: '视频加载失败：${friendlyError(snapshot.error)}',
              onRetry: () => setState(() => _prepareFuture = _prepareVideo()),
              dark: true,
            );
          }
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onPanStart: _onVideoPanStart,
                  onPanUpdate: _onVideoPanUpdate,
                  onPanEnd: _onVideoPanEnd,
                  child: Video(
                    controller: _controller,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),
                ),
              ),
              if (_gestureText != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _gestureText!,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
                ),
              if (_controlsVisible)
                Align(
                  alignment: Alignment.topCenter,
                  child: VideoTopBar(
                    title: _file.name,
                    isDeleting: _isDeleting,
                    onBack: () => Navigator.of(context).pop(),
                    onDelete: _isDeleting ? null : _deleteCurrent,
                  ),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: _controlsVisible
                    ? VideoControlBar(
                        player: _player,
                        canPrevious: _index > 0,
                        canNext: _index + 1 < _videos.length,
                        isLandscape: _isLandscape,
                        onPrevious: () => _openAt(_index - 1),
                        onNext: () => _openAt(_index + 1),
                        onBack15: () => _seekBy(-15),
                        onForward15: () => _seekBy(15),
                        onToggleOrientation: _toggleOrientation,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class VideoTopBar extends StatelessWidget {
  const VideoTopBar({
    required this.title,
    required this.isDeleting,
    required this.onBack,
    required this.onDelete,
    this.trailing,
    super.key,
  });

  final String title;
  final bool isDeleting;
  final VoidCallback onBack;
  final VoidCallback? onDelete;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 18),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              color: Colors.white,
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ?trailing,
            if (onDelete != null || isDeleting)
              IconButton(
                tooltip: '删除',
                color: Colors.white,
                icon: isDeleting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

class VideoControlBar extends StatelessWidget {
  const VideoControlBar({
    required this.player,
    required this.canPrevious,
    required this.canNext,
    required this.isLandscape,
    required this.onPrevious,
    required this.onNext,
    required this.onBack15,
    required this.onForward15,
    required this.onToggleOrientation,
    super.key,
  });

  final Player player;
  final bool canPrevious;
  final bool canNext;
  final bool isLandscape;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onBack15;
  final VoidCallback onForward15;
  final VoidCallback onToggleOrientation;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StreamBuilder<Duration>(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (context, positionSnapshot) {
                return StreamBuilder<Duration>(
                  stream: player.stream.duration,
                  initialData: player.state.duration,
                  builder: (context, durationSnapshot) {
                    final position = positionSnapshot.data ?? Duration.zero;
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final max = duration.inMilliseconds.toDouble();
                    final value = max <= 0
                        ? 0.0
                        : position.inMilliseconds
                              .clamp(0, duration.inMilliseconds)
                              .toDouble();
                    return Row(
                      children: [
                        Text(
                          formatDuration(position),
                          style: const TextStyle(color: Colors.white),
                        ),
                        Expanded(
                          child: Slider(
                            value: value,
                            max: max <= 0 ? 1 : max,
                            onChanged: max <= 0
                                ? null
                                : (next) => player.seek(
                                    Duration(milliseconds: next.round()),
                                  ),
                          ),
                        ),
                        Text(
                          formatDuration(duration),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: isLandscape ? '竖屏' : '横屏',
                  color: Colors.white,
                  icon: Icon(
                    isLandscape
                        ? Icons.stay_current_portrait
                        : Icons.stay_current_landscape,
                  ),
                  onPressed: onToggleOrientation,
                ),
                const Spacer(),
                IconButton(
                  tooltip: '上一部',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: canPrevious ? onPrevious : null,
                ),
                IconButton(
                  tooltip: '后退 15 秒',
                  color: Colors.white,
                  icon: const SecondsIcon(label: '15'),
                  onPressed: onBack15,
                ),
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (context, snapshot) {
                    final playing = snapshot.data ?? false;
                    return IconButton.filled(
                      tooltip: playing ? '暂停' : '播放',
                      iconSize: 32,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () => playing ? player.pause() : player.play(),
                    );
                  },
                ),
                IconButton(
                  tooltip: '前进 15 秒',
                  color: Colors.white,
                  icon: const SecondsIcon(label: '15', forward: true),
                  onPressed: onForward15,
                ),
                IconButton(
                  tooltip: '下一部',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_next),
                  onPressed: canNext ? onNext : null,
                ),
                const Spacer(),
                const SizedBox(width: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
