
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../models/anime_part_dto.dart';
import '../models/anime.dart';
import '../providers/anime_providers.dart';

class AnimePlayerMediaKitScreen extends ConsumerStatefulWidget {
  final String animeTitle;
  final List<AnimeEpisode> episodes;
  final int initialEpisodeIndex;

  final List<AnimePartDTO> parts;
  final String? currentPartName;

  const AnimePlayerMediaKitScreen({
    super.key,
    required this.animeTitle,
    required this.episodes,
    required this.initialEpisodeIndex,
    this.parts = const [],
    this.currentPartName,
  });

  @override
  ConsumerState<AnimePlayerMediaKitScreen> createState() =>
      _AnimePlayerMediaKitScreenState();
}

class _AnimePlayerMediaKitScreenState
    extends ConsumerState<AnimePlayerMediaKitScreen> {
  VideoPlayerController? _controller;

  late List<AnimeEpisode> _episodes;
  late int _currentEpisodeIndex;

  String? _currentPartName;

  bool _loading = false;
  bool _isFullscreen = false;
  bool _isSeeking = false;

  bool _fullscreenControlsVisible = true;
  Timer? _fullscreenControlsTimer;

  String? _error;

  int _loadRequestId = 0;
  int _partRequestId = 0;

  double? _seekValue;
  double _playbackRate = 1.0;

  Stopwatch? _episodeStopwatch;
  bool _firstPositionLogged = false;

  static const Duration _controlsHideDelay = Duration(seconds: 2);
  static const int _skipIntroSeconds = 90;

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

    _episodes = List.of(widget.episodes);
    _currentPartName = widget.currentPartName;

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
    _partRequestId++;

    _fullscreenControlsTimer?.cancel();

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

  // ============================================================
  // STREAM PRELOAD
  // ============================================================

  void _preloadNextEpisode(int currentIndex) {
    final nextIndex = currentIndex + 1;

    if (nextIndex >= _episodes.length) {
      return;
    }

    final nextEpisode = _episodes[nextIndex];
    final service = ref.read(animeServiceProvider);

    debugPrint(
      '[PLAYER PRELOAD] Start: Episode ${nextEpisode.number}',
    );

    // Chỉ phân giải URL HLS, không khởi tạo thêm VideoPlayerController.
    // AnimeService sẽ lưu kết quả vào cache để lần chuyển tập dùng lại.
    unawaited(service.preloadStream(nextEpisode.url));
  }

  // ============================================================
  // FULLSCREEN CONTROLS
  // ============================================================

  void _showFullscreenControls() {
    if (!mounted || !_isFullscreen) return;

    setState(() {
      _fullscreenControlsVisible = true;
    });

    _scheduleFullscreenControlsHide();
  }

  void _scheduleFullscreenControlsHide() {
    _fullscreenControlsTimer?.cancel();

    if (!mounted || !_isFullscreen) return;

    _fullscreenControlsTimer = Timer(_controlsHideDelay, () {
      if (!mounted || !_isFullscreen) return;

      setState(() {
        _fullscreenControlsVisible = false;
      });
    });
  }

  void _hideFullscreenControls() {
    _fullscreenControlsTimer?.cancel();

    if (!mounted) return;

    setState(() {
      _fullscreenControlsVisible = false;
    });
  }

  Future<void> _toggleFullscreenPlayback() async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized || _loading) {
      return;
    }

    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }

    if (!mounted) return;

    _showFullscreenControls();
  }

  // ============================================================
  // PLAYER
  // ============================================================

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

    // Ghi nhận thời điểm video bắt đầu có tiến trình phát.
    // Đây không phải thời điểm chính xác của frame đầu tiên được render.
    if (!_firstPositionLogged &&
        controller.value.isInitialized &&
        controller.value.position > Duration.zero) {
      _firstPositionLogged = true;

      final elapsed = _episodeStopwatch?.elapsedMilliseconds;

      debugPrint(
        '[PERF] First playback position: ${elapsed ?? -1}ms',
      );
    }

    setState(() {});
  }

  Future<void> _loadEpisode(int index) async {
    if (index < 0 || index >= _episodes.length) return;

    final requestId = ++_loadRequestId;
    final totalWatch = Stopwatch()..start();

    _episodeStopwatch = totalWatch;
    _firstPositionLogged = false;

    final episode = _episodes[index];
    final service = ref.read(animeServiceProvider);

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

    VideoPlayerController? newController;

    try {
      debugPrint('========== ANIME PLAYER ==========');
      debugPrint('[PLAYER] Part: $_currentPartName');
      debugPrint('[PLAYER] Episode: ${episode.number}');
      debugPrint('[PLAYER] Episode URL: ${episode.url}');

      // Bắt đầu preload tập kế tiếp ngay khi bắt đầu tải tập hiện tại.
      // Hai request chạy song song.
      _preloadNextEpisode(index);

      // Lấy URL HLS và giải phóng controller cũ đồng thời.
      final streamWatch = Stopwatch()..start();

      final streamFuture = service
          .getStream(episode.url)
          .timeout(const Duration(seconds: 30));

      final disposeFuture = oldController?.dispose() ??
          Future<void>.value();

      final results = await Future.wait<dynamic>([
        disposeFuture,
        streamFuture,
      ]);

      final stream = results[1] as AnimeStream;

      debugPrint(
        '[PERF] getStream: ${streamWatch.elapsedMilliseconds}ms',
      );

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

      final initializeWatch = Stopwatch()..start();

      await newController.initialize();

      debugPrint(
        '[PERF] initialize: ${initializeWatch.elapsedMilliseconds}ms',
      );

      if (!mounted || requestId != _loadRequestId) {
        newController.removeListener(_onPlayerUpdate);
        await newController.dispose();
        return;
      }

      debugPrint('[PLAYER] Video initialized.');
      debugPrint('[PLAYER] Duration: ${newController.value.duration}');
      debugPrint('[PLAYER] Size: ${newController.value.size}');

      await newController.setPlaybackSpeed(1.0);

      final playWatch = Stopwatch()..start();

      await newController.play();

      debugPrint(
        '[PERF] play call: ${playWatch.elapsedMilliseconds}ms',
      );

      if (!mounted || requestId != _loadRequestId) return;

      setState(() {
        _loading = false;
        _error = null;
      });

      if (_isFullscreen) {
        _showFullscreenControls();
      }

      debugPrint('[PLAYER] Playing.');
      debugPrint(
        '[PERF] Total until play call: ${totalWatch.elapsedMilliseconds}ms',
      );
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

      if (_isFullscreen) {
        _showFullscreenControls();
      }
    }
  }

  Future<void> _onPartSelected(AnimePartDTO part) async {
    if (part.name == _currentPartName || _loading) return;

    final requestId = ++_partRequestId;

    _loadRequestId++;

    final controller = _controller;

    if (controller != null && controller.value.isPlaying) {
      await controller.pause();
    }

    if (!mounted || requestId != _partRequestId) return;

    setState(() {
      _loading = true;
      _error = null;
      _isSeeking = false;
      _seekValue = null;
    });

    try {
      debugPrint('========== CHANGE ANIME PART ==========');
      debugPrint('[PART] Name: ${part.name}');
      debugPrint('[PART] URL: ${part.url}');

      final episodeWatch = Stopwatch()..start();

      final newEpisodes = await ref
          .read(animeServiceProvider)
          .getEpisodes(part.url)
          .timeout(const Duration(seconds: 30));

      debugPrint(
        '[PERF] getEpisodes: ${episodeWatch.elapsedMilliseconds}ms',
      );

      if (!mounted || requestId != _partRequestId) return;

      if (newEpisodes.isEmpty) {
        throw Exception('Phần này chưa có tập phim nào.');
      }

      setState(() {
        _episodes = List.of(newEpisodes);
        _currentPartName = part.name;
        _currentEpisodeIndex = 0;
        _error = null;
      });

      debugPrint('[PART] Episodes: ${newEpisodes.length}');

      await _loadEpisode(0);
    } catch (e, stackTrace) {
      if (!mounted || requestId != _partRequestId) return;

      debugPrint('[PART ERROR] $e');
      debugPrint('[PART STACKTRACE] $stackTrace');

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

  // ============================================================
  // FULLSCREEN
  // ============================================================

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      _fullscreenControlsTimer?.cancel();

      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);

      if (!mounted) return;

      setState(() {
        _isFullscreen = false;
        _fullscreenControlsVisible = true;
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
        _fullscreenControlsVisible = true;
      });

      _scheduleFullscreenControlsHide();
    }
  }

  // ============================================================
  // SEEK
  // ============================================================

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

  Future<void> _skipIntro() async {
    await _seekRelative(_skipIntroSeconds);

    if (_isFullscreen) {
      _showFullscreenControls();
    }
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

      if (_isFullscreen) {
        _scheduleFullscreenControlsHide();
      }
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

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
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
          if (widget.parts.isNotEmpty) _buildPartsChips(),
          _buildEpisodeList(),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 56,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Chưa có tập phim nào.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // FULLSCREEN PLAYER
  // ============================================================

  Widget _buildFullscreenPlayer() {
    final controller = _controller;

    final isPlaying = controller?.value.isPlaying ?? false;

    final canTogglePlayback =
        controller != null && controller.value.isInitialized && !_loading;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: Center(
            child: _buildVideo(),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _showFullscreenControls,
            child: const SizedBox.expand(),
          ),
        ),
        if (_fullscreenControlsVisible && canTogglePlayback)
          Center(
            child: Material(
              color: Colors.black45,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggleFullscreenPlayback,
                child: SizedBox(
                  width: 68,
                  height: 68,
                  child: Icon(
                    isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
              ),
            ),
          ),
        if (_fullscreenControlsVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Listener(
                onPointerDown: (_) {
                  _scheduleFullscreenControlsHide();
                },
                child: _buildControlsBar(),
              ),
            ),
          ),
      ],
    );
  }

  // ============================================================
  // NORMAL PLAYER
  // ============================================================

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
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 12),
            Text(
              _loading ? 'Đang tải nguồn phát...' : 'Đang khởi tạo video...',
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
            child: const CircularProgressIndicator(color: Colors.white),
          ),
        if (_loading)
          Container(
            color: Colors.black54,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(color: Colors.white),
          ),
      ],
    );
  }

  // ============================================================
  // PART SELECTOR
  // ============================================================

  Widget _buildPartsChips() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Phần / Mùa',
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: widget.parts.map((part) {
                final isSelected = part.name == _currentPartName;

                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(part.name),
                    selected: isSelected,
                    onSelected: _loading ? null : (_) => _onPartSelected(part),
                    showCheckmark: false,
                    selectedColor: colorScheme.primaryContainer,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    side: BorderSide(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.outlineVariant,
                    ),
                    labelStyle: TextStyle(
                      color: isSelected
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurface,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // PLAYER CONTROLS
  // ============================================================

  Widget _buildControlsBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final controller = _controller;

    final initialized = controller != null && controller.value.isInitialized;

    final duration = initialized ? controller.value.duration : Duration.zero;

    final position = initialized ? controller.value.position : Duration.zero;

    final maxMilliseconds = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;

    final currentMilliseconds = _isSeeking
        ? (_seekValue ?? 0).clamp(0.0, maxMilliseconds)
        : position.inMilliseconds.toDouble().clamp(0.0, maxMilliseconds);

    final enabled = initialized && !_loading;

    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
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
              activeTrackColor: colorScheme.primary,
              inactiveTrackColor:
              colorScheme.onSurface.withValues(alpha: 0.24),
              thumbColor: colorScheme.primary,
              overlayColor: colorScheme.primary.withValues(alpha: 0.12),
            ),
            child: Slider(
              min: 0,
              max: maxMilliseconds,
              value: currentMilliseconds,
              activeColor: colorScheme.primary,
              inactiveColor: colorScheme.onSurface.withValues(alpha: 0.24),
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
                icon: Icons.fast_forward,
                tooltip: 'Skip Intro (+90 giây)',
                enabled: enabled,
                onPressed: _skipIntro,
              ),
              _buildControlButton(
                icon: Icons.skip_next,
                tooltip: 'Tập tiếp theo',
                enabled: enabled &&
                    _currentEpisodeIndex < _episodes.length - 1,
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
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 12,
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      Text(
                        ' / ',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        _formatDuration(duration),
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontFeatures: const [
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
                color: colorScheme.surfaceContainer,
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
                                    ? colorScheme.primary
                                    : colorScheme.onSurface,
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
                              color: colorScheme.primary,
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
                    style: TextStyle(
                      color: colorScheme.onSurface,
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
                color: colorScheme.onSurface,
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
    final colorScheme = Theme.of(context).colorScheme;

    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: 34,
        minHeight: 40,
      ),
      color: colorScheme.onSurface,
      disabledColor: colorScheme.onSurface.withValues(alpha: 0.24),
      tooltip: tooltip,
      icon: Icon(icon, size: 25),
      onPressed: enabled ? onPressed : null,
    );
  }

  Widget _buildPlayPauseButton({
    required VideoPlayerController? controller,
    required bool enabled,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPlaying = controller?.value.isPlaying ?? false;

    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: 40,
        minHeight: 42,
      ),
      color: colorScheme.onSurface,
      disabledColor: colorScheme.onSurface.withValues(alpha: 0.24),
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

        if (_isFullscreen) {
          _showFullscreenControls();
        }
      },
    );
  }

  // ============================================================
  // ERROR
  // ============================================================

  Widget _buildErrorState() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              color: colorScheme.error,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              'Lỗi phát video',
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Không thể phát video.',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
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

  // ============================================================
  // EPISODE LIST
  // ============================================================

  Widget _buildEpisodeList() {
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: 100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 4,
            ),
            child: Text(
              'Danh sách tập',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
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
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerHighest,
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
                                ? colorScheme.primary
                                : colorScheme.outlineVariant,
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
                                    ? colorScheme.onPrimaryContainer
                                    : colorScheme.onSurface,
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
                                    ? colorScheme.onPrimaryContainer
                                    .withValues(alpha: 0.8)
                                    : colorScheme.onSurfaceVariant,
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
