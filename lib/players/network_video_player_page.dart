import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../emby_client.dart';
import '../models.dart';
import '../utils.dart';
import '../widgets/common.dart';
import 'video_player_page.dart';

class NetworkVideoPlayerPage extends StatefulWidget {
  const NetworkVideoPlayerPage({
    required this.title,
    required this.client,
    required this.item,
    super.key,
  });

  final String title;
  final EmbyClient client;
  final EmbyItem item;

  @override
  State<NetworkVideoPlayerPage> createState() =>
      _NetworkVideoPlayerPageState();
}

class _NetworkVideoPlayerPageState extends State<NetworkVideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  late Future<void> _prepareFuture;
  bool _isLandscape = false;
  bool _controlsVisible = true;
  VideoGestureMode _gestureMode = VideoGestureMode.none;
  Offset _gestureStart = Offset.zero;
  Duration _gestureStartPosition = Duration.zero;
  double _gestureStartBrightness = 0.5;
  double _gestureStartVolume = 0.5;
  String? _gestureText;
  EmbyVideoQuality _quality = EmbyVideoQuality.original;
  bool _dolbyVisionChecked = false;
  Timer? _progressTimer;
  final String _playSessionId = DateTime.now().microsecondsSinceEpoch.toString();

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
    _progressTimer?.cancel();
    _reportPlaybackStopped();
    unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(ScreenBrightness.instance.resetApplicationScreenBrightness());
    unawaited(_player.dispose());
    super.dispose();
  }

  void _startProgressReporting() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _reportPlaybackProgress();
    });
  }

  Future<void> _reportPlaybackStart() async {
    try {
      await widget.client.reportPlaybackStart(
        widget.item,
        playSessionId: _playSessionId,
      );
    } catch (_) {}
  }

  Future<void> _reportPlaybackProgress() async {
    try {
      final position = _player.state.position;
      final isPaused = !_player.state.playing;
      await widget.client.reportPlaybackProgress(
        widget.item,
        positionTicks: position.inMicroseconds * 10,
        isPaused: isPaused,
        playSessionId: _playSessionId,
      );
    } catch (_) {}
  }

  Future<void> _reportPlaybackStopped() async {
    try {
      final position = _player.state.position;
      await widget.client.reportPlaybackStopped(
        widget.item,
        positionTicks: position.inMicroseconds * 10,
        playSessionId: _playSessionId,
      );
    } catch (_) {}
  }

  bool _isDolbyVisionContent(String uri) {
    final lowerUri = uri.toLowerCase();
    return lowerUri.contains('dolby') ||
        lowerUri.contains('dv') ||
        lowerUri.contains('dovi') ||
        widget.item.name.toLowerCase().contains('dolby') ||
        widget.item.name.toLowerCase().contains('dv');
  }

  Future<void> _checkDolbyVisionSupport(String uri) async {
    if (_dolbyVisionChecked) return;
    _dolbyVisionChecked = true;

    if (!_isDolbyVisionContent(uri)) return;

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
    final uri = widget.client.streamUri(
      widget.item,
      maxHeight: _quality.height,
      maxBitrate: _quality.bitrate,
    );
    debugPrint('[Player] Opening stream: $uri');
    await _checkDolbyVisionSupport(uri.toString());
    await _player.open(Media(uri.toString()), play: true);
    debugPrint('[Player] Stream opened successfully');
    _reportPlaybackStart();
    _startProgressReporting();
  }

  Future<void> _changeQuality(EmbyVideoQuality quality) async {
    if (quality == _quality) return;
    setState(() {
      _quality = quality;
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
      _gestureStartBrightness =
          await ScreenBrightness.instance.application;
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
    if (size == null) return;
    final delta = details.localPosition - _gestureStart;
    if (_gestureMode == VideoGestureMode.none) {
      if (delta.distance < 14) return;
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
          '${seconds >= 0 ? '+' : ''}$seconds s  ${formatDuration(target)}',
        );
      case VideoGestureMode.brightness:
        final next =
            (_gestureStartBrightness - delta.dy / size.height).clamp(0.0, 1.0);
        await ScreenBrightness.instance.setApplicationScreenBrightness(next);
        _setGestureText('亮度 ${(next * 100).round()}%');
      case VideoGestureMode.volume:
        final next =
            (_gestureStartVolume - delta.dy / size.height).clamp(0.0, 1.0);
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

  void _showQualityDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('画质选择'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: EmbyVideoQuality.all.length,
            itemBuilder: (context, index) {
              final q = EmbyVideoQuality.all[index];
              return ListTile(
                title: Text(q.label),
                leading: Radio<EmbyVideoQuality>(
                  value: q,
                  groupValue: _quality,
                  onChanged: (value) {
                    Navigator.of(context).pop();
                    if (value != null) _changeQuality(value);
                  },
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _changeQuality(q);
                },
              );
            },
          ),
        ),
      ),
    );
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
              onRetry: () =>
                  setState(() => _prepareFuture = _prepareVideo()),
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
                      style:
                          const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
                ),
              if (_controlsVisible)
                Align(
                  alignment: Alignment.topCenter,
                  child: VideoTopBar(
                    title: widget.title,
                    isDeleting: false,
                    onBack: () => Navigator.of(context).pop(),
                    onDelete: null,
                  ),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: _controlsVisible
                    ? EmbyVideoControlBar(
                        player: _player,
                        quality: _quality,
                        isLandscape: _isLandscape,
                        onBack15: () => _seekBy(-15),
                        onForward15: () => _seekBy(15),
                        onToggleOrientation: _toggleOrientation,
                        onShowQuality: _showQualityDialog,
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

class EmbyVideoControlBar extends StatelessWidget {
  const EmbyVideoControlBar({
    required this.player,
    required this.quality,
    required this.isLandscape,
    required this.onBack15,
    required this.onForward15,
    required this.onToggleOrientation,
    required this.onShowQuality,
    super.key,
  });

  final Player player;
  final EmbyVideoQuality quality;
  final bool isLandscape;
  final VoidCallback onBack15;
  final VoidCallback onForward15;
  final VoidCallback onToggleOrientation;
  final VoidCallback onShowQuality;

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
                                      Duration(
                                          milliseconds: next.round()),
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
                IconButton(
                  tooltip: '画质: ${quality.label}',
                  color: Colors.white,
                  icon: const Icon(Icons.high_quality),
                  onPressed: onShowQuality,
                ),
                const Spacer(),
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
                      icon: Icon(
                          playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () =>
                          playing ? player.pause() : player.play(),
                    );
                  },
                ),
                IconButton(
                  tooltip: '前进 15 秒',
                  color: Colors.white,
                  icon: const SecondsIcon(label: '15', forward: true),
                  onPressed: onForward15,
                ),
                const Spacer(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
