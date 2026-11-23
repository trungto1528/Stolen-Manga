
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../models/anime.dart';
import '../providers/anime_providers.dart';

class AnimePlayerMediaKitScreen extends ConsumerStatefulWidget {
  final String animeTitle;
  final List<AnimeEpisode> episodes;
  final int initialEpisodeIndex;

  const AnimePlayerMediaKitScreen({
    super.key,
    required this.animeTitle,
    required this.episodes,
    required this.initialEpisodeIndex,
  });

  @override
  ConsumerState<AnimePlayerMediaKitScreen> createState() =>
      _AnimePlayerMediaKitScreenState();
}

class _AnimePlayerMediaKitScreenState
    extends ConsumerState<AnimePlayerMediaKitScreen> {
  VideoPlayerController? _controller;

  late final List<AnimeEpisode> _episodes;
  late int _currentEpisodeIndex;

  bool _loading = false;
  bool _isFullscreen = false;
  bool _isSeeking = false;

  String? _error;

  int _loadRequestId = 0;

  double? _seekValue;
  double _playbackRate = 1.0;

  static const List<double> _playbackRates = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  @override
  void initState() {
    super.initState();

    _episodes = List.unmodifiable(widget.episodes);

    if (_episodes.isEmpty) {
      _currentEpisodeIndex = 0;
      _error = 'Anime này chưa có danh sách tập.';
      return;
    }

    _currentEpisodeIndex = widget.initialEpisodeIndex.clamp(
      0,
      _episodes.length - 1,
    );

    _loadEpisode(_currentEpisodeIndex);
  }

  @override
  void dispose() {
    _loadRequestId++;

    final controller = _controller;
    _controller = null;

    if (controller != null) {
      controller.removeListener(_onPlayerUpdate);
      unawaited(controller.dispose());
    }

    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }

    super.dispose();
  }

  void _onPlayerUpdate() {
    if (!mounted) return;

    final controller = _controller;

    if (controller == null) return;

    if (controller.value.hasError && _error == null) {
      setState(() {
        _error = controller.value.errorDescription ?? 'Không thể phát video.';
        _loading = false;
      });

      return;
    }

    setState(() {});
  }

  Future<void> _loadEpisode(int index) async {
    if (index < 0 || index >= _episodes.length) return;

    final requestId = ++_loadRequestId;

    final oldController = _controller;

    if (oldController != null) {
      oldController.removeListener(_onPlayerUpdate);
    }

    setState(() {
      _currentEpisodeIndex = index;
      _loading = true;
      _error = null;
      _isSeeking = false;
      _seekValue = null;
      _playbackRate = 1.0;
      _controller = null;
    });

    if (oldController != null) {
      await oldController.dispose();
    }

    if (!mounted || requestId != _loadRequestId) return;

    VideoPlayerController? newController;

    try {
      final episode = _episodes[index];

      debugPrint('========== ANIME PLAYER ==========');
      debugPrint('[PLAYER] Episode: ${episode.number}');
      debugPrint('[PLAYER] Episode URL: ${episode.url}');

      final stream = await ref
          .read(animeServiceProvider)
          .getStream(episode.url)
          .timeout(const Duration(seconds: 30));

      if (!mounted || requestId != _loadRequestId) return;

      final streamUrl = stream.hlsUrl.trim();

      debugPrint('[PLAYER] HLS URL: $streamUrl');
      debugPrint('[PLAYER] Headers: ${stream.headers}');

      if (streamUrl.isEmpty) {
        throw Exception('Không tìm thấy URL video.');
      }

      final headers = <String, String>{
        'Referer': 'https://animehay17.site/',
        'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
        ...stream.headers,
      };

      newController = VideoPlayerController.networkUrl(
        Uri.parse(streamUrl),
        httpHeaders: headers,
      );

      _controller = newController;

      newController.addListener(_onPlayerUpdate);

      debugPrint('[PLAYER] Initializing video...');

      await newController.initialize();

      if (!mounted || requestId != _loadRequestId) {
        newController.removeListener(_onPlayerUpdate);
        await newController.dispose();
        return;
      }

      debugPrint('[PLAYER] Video initialized.');
      debugPrint('[PLAYER] Duration: ${newController.value.duration}');
      debugPrint('[PLAYER] Size: ${newController.value.size}');

      await newController.setPlaybackSpeed(1.0);

      await newController.play();

      if (!mounted || requestId != _loadRequestId) return;

      setState(() {
        _loading = false;
        _error = null;
      });

      debugPrint('[PLAYER] Playing.');
    } catch (e, stackTrace) {
      if (!mounted || requestId != _loadRequestId) {
        if (newController != null && newController != _controller) {
          newController.removeListener(_onPlayerUpdate);
          await newController.dispose();
        }
        return;
      }

      debugPrint('[PLAYER ERROR] $e');
      debugPrint('[PLAYER STACKTRACE] $stackTrace');

      if (newController != null) {
        newController.removeListener(_onPlayerUpdate);

        if (_controller == newController) {
          _controller = null;
        }

        await newController.dispose();
      }

      if (!mounted || requestId != _loadRequestId) return;

      setState(() {
        _loading = false;
        _error = _getReadableError(e);
      });
    }
  }

  String _getReadableError(Object error) {
    final message = error.toString();

    if (message.contains('TimeoutException')) {
      return 'Kết nối đến nguồn phát quá thời gian. Vui lòng thử lại.';
    }

    return message;
  }

  void _retry() {
    if (_episodes.isEmpty) return;

    _loadEpisode(_currentEpisodeIndex);
  }

  void _previousEpisode() {
    if (_currentEpisodeIndex > 0) {
      _loadEpisode(_currentEpisodeIndex - 1);
    }
  }

  void _nextEpisode() {
    if (_currentEpisodeIndex < _episodes.length - 1) {
      _loadEpisode(_currentEpisodeIndex + 1);
    }
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
      );

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);

      if (!mounted) return;

      setState(() {
        _isFullscreen = false;
      });
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);

      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
      );

      if (!mounted) return;

      setState(() {
        _isFullscreen = true;
      });
    }
  }

  Future<void> _seekRelative(int seconds) async {
    if (_loading) return;

    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final position = controller.value.position;
    final duration = controller.value.duration;

    final target = position + Duration(seconds: seconds);

    final clampedMilliseconds = target.inMilliseconds.clamp(
      0,
      duration.inMilliseconds,
    );

    await controller.seekTo(
      Duration(milliseconds: clampedMilliseconds),
    );
  }

  Future<void> _seekTo(double milliseconds) async {
    if (_loading) return;

    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    await controller.seekTo(
      Duration(milliseconds: milliseconds.round()),
    );
  }

  Future<void> _changePlaybackRate(double rate) async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      await controller.setPlaybackSpeed(rate);

      if (!mounted) return;

      setState(() {
        _playbackRate = rate;
      });
    } catch (e) {
      debugPrint('[PLAYER SPEED ERROR] $e');
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$mm:$ss';
    }

    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _isFullscreen
          ? null
          : AppBar(
        title: Text(
          widget.animeTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _episodes.isEmpty
          ? _buildEmptyState()
          : _isFullscreen
          ? _buildFullscreenPlayer()
          : Column(
        children: [
          _buildPlayerArea(),
          _buildEpisodeList(),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text(
              'Chưa có tập phim nào.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullscreenPlayer() {
    return SafeArea(
      top: false,
      bottom: false,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: _buildVideo(),
            ),
          ),
          _buildControlsBar(),
        ],
      ),
    );
  }

  Widget _buildPlayerArea() {
    final controller = _controller;

    final aspectRatio = controller != null &&
        controller.value.isInitialized &&
        controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: _buildVideoContent(),
          ),
        ),
        _buildControlsBar(),
      ],
    );
  }

  Widget _buildVideo() {
    return _buildVideoContent();
  }

  Widget _buildVideoContent() {
    final controller = _controller;

    if (_error != null && !_loading) {
      return _buildErrorState();
    }

    if (controller == null || !controller.value.isInitialized) {
      return Container(
        width: double.infinity,
        color: Colors.black,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
              color: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              _loading
                  ? 'Đang tải nguồn phát...'
                  : 'Đang khởi tạo video...',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        VideoPlayer(controller),
        if (controller.value.isBuffering)
          Container(
            color: Colors.black38,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(
              color: Colors.white,
            ),
          ),
        if (_loading)
          Container(
            color: Colors.black54,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(
              color: Colors.white,
            ),
          ),
      ],
    );
  }

  Widget _buildControlsBar() {
    final controller = _controller;

    final initialized = controller != null && controller.value.isInitialized;

    final duration = initialized
        ? controller.value.duration
        : Duration.zero;

    final position = initialized
        ? controller.value.position
        : Duration.zero;

    final maxMilliseconds = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;

    final currentMilliseconds = _isSeeking
        ? (_seekValue ?? 0).clamp(0.0, maxMilliseconds)
        : position.inMilliseconds.toDouble().clamp(
      0.0,
      maxMilliseconds,
    );

    final enabled = initialized && !_loading;

    return Container(
      width: double.infinity,
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 5,
              ),
              overlayShape: const RoundSliderOverlayShape(
                overlayRadius: 10,
              ),
            ),
            child: Slider(
              min: 0,
              max: maxMilliseconds,
              value: currentMilliseconds,
              activeColor: Theme.of(context).colorScheme.primary,
              inactiveColor: Colors.white30,
              onChanged: enabled && duration.inMilliseconds > 0
                  ? (value) {
                setState(() {
                  _isSeeking = true;
                  _seekValue = value;
                });
              }
                  : null,
              onChangeEnd: enabled && duration.inMilliseconds > 0
                  ? (value) {
                _seekTo(value);

                setState(() {
                  _isSeeking = false;
                  _seekValue = null;
                });
              }
                  : null,
            ),
          ),
          Row(
            children: [
              _buildControlButton(
                icon: Icons.skip_previous,
                tooltip: 'Tập trước',
                enabled: enabled && _currentEpisodeIndex > 0,
                onPressed: _previousEpisode,
              ),
              _buildControlButton(
                icon: Icons.replay_10,
                tooltip: 'Lùi 10 giây',
                enabled: enabled,
                onPressed: () => _seekRelative(-10),
              ),
              _buildPlayPauseButton(
                controller: controller,
                enabled: enabled,
              ),
              _buildControlButton(
                icon: Icons.forward_10,
                tooltip: 'Tiến 10 giây',
                enabled: enabled,
                onPressed: () => _seekRelative(10),
              ),
              _buildControlButton(
                icon: Icons.skip_next,
                tooltip: 'Tập tiếp theo',
                enabled: enabled && _currentEpisodeIndex < _episodes.length - 1,
                onPressed: _nextEpisode,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatDuration(
                          Duration(
                            milliseconds: currentMilliseconds.round(),
                          ),
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFeatures: [
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      const Text(
                        ' / ',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        _formatDuration(duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontFeatures: [
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<double>(
                enabled: enabled,
                tooltip: 'Tốc độ phát',
                initialValue: _playbackRate,
                color: const Color(0xFF242424),
                onSelected: _changePlaybackRate,
                itemBuilder: (context) {
                  return _playbackRates.map((rate) {
                    final selected = rate == _playbackRate;

                    return PopupMenuItem<double>(
                      value: rate,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 54,
                            child: Text(
                              '${rate}x',
                              style: TextStyle(
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.white,
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (selected)
                            Icon(
                              Icons.check,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        ],
                      ),
                    );
                  }).toList();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '${_playbackRate}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 40,
                ),
                color: Colors.white,
                tooltip: _isFullscreen
                    ? 'Thoát toàn màn hình'
                    : 'Toàn màn hình',
                icon: Icon(
                  _isFullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  size: 24,
                ),
                onPressed: _toggleFullscreen,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: 34,
        minHeight: 40,
      ),
      color: Colors.white,
      disabledColor: Colors.white24,
      tooltip: tooltip,
      icon: Icon(
        icon,
        size: 25,
      ),
      onPressed: enabled ? onPressed : null,
    );
  }

  Widget _buildPlayPauseButton({
    required VideoPlayerController? controller,
    required bool enabled,
  }) {
    final isPlaying = controller?.value.isPlaying ?? false;

    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: 40,
        minHeight: 42,
      ),
      color: Colors.white,
      disabledColor: Colors.white24,
      tooltip: isPlaying ? 'Tạm dừng' : 'Phát',
      icon: Icon(
        isPlaying ? Icons.pause : Icons.play_arrow,
        size: 32,
      ),
      onPressed: !enabled
          ? null
          : () {
        final currentController = _controller;

        if (currentController == null) return;

        if (currentController.value.isPlaying) {
          currentController.pause();
        } else {
          currentController.play();
        }
      },
    );
  }

  Widget _buildErrorState() {
    return Container(
      width: double.infinity,
      color: Colors.black87,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.white,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Lỗi phát video',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Không thể phát video.',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodeList() {
    final currentEpisode = _episodes[_currentEpisodeIndex];

    return SizedBox(
      height: 100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Tập ${currentEpisode.number}: ${currentEpisode.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: 'Tập trước',
                  icon: const Icon(Icons.skip_previous, size: 20),
                  onPressed: _currentEpisodeIndex > 0 && !_loading
                      ? _previousEpisode
                      : null,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: 'Tập tiếp theo',
                  icon: const Icon(Icons.skip_next, size: 20),
                  onPressed: _currentEpisodeIndex < _episodes.length - 1 &&
                      !_loading
                      ? _nextEpisode
                      : null,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 2,
              ),
              itemCount: _episodes.length,
              itemBuilder: (context, index) {
                final episode = _episodes[index];
                final isCurrent = index == _currentEpisodeIndex;

                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Material(
                    color: isCurrent
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _loading ? null : () => _loadEpisode(index),
                      child: Container(
                        width: 76,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isCurrent
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Tập ${episode.number}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isCurrent
                                    ? Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              episode.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 9,
                                height: 1.1,
                                color: isCurrent
                                    ? Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer
                                    .withValues(alpha: 0.8)
                                    : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
