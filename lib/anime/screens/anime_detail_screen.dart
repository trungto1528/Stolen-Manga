
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/anime_part_dto.dart';
import '../../offline/service/offline_mode_service.dart';
import '../models/anime.dart';
import '../services/anime_service.dart';
import '../services/anime_download_service.dart';
import 'anime_player_mediakit_screen.dart';

class AnimeDetailScreen extends ConsumerStatefulWidget {
  final String animeUrl;

  const AnimeDetailScreen({super.key, required this.animeUrl});

  @override
  ConsumerState<AnimeDetailScreen> createState() => _AnimeDetailScreenState();
}

class _AnimeDetailScreenState extends ConsumerState<AnimeDetailScreen> {
  final AnimeService _animeService = AnimeService();
  final AnimeDownloadService _downloadService =
      AnimeDownloadService.instance;

  AnimeDetail? _detail;
  bool _loading = true;
  String? _error;

  List<AnimePartDTO> _parts = [];
  String? _selectedPartName;

  final Map<String, bool> _downloadedEpisodes = {};
  final Set<String> _checkingDownloads = {};

  bool get _isOffline => OfflineModeService.isOffline.value;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_isOffline) {
        await _loadOfflineDetail();
      } else {
        await _loadOnlineDetail();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadOnlineDetail() async {
    final detail = await _animeService.getDetail(widget.animeUrl);

    if (!mounted) return;

    setState(() {
      _detail = detail;
      _loading = false;
    });

    await Future.wait([
      _loadParts(),
      _loadDownloadStates(detail),
    ]);
  }

  Future<void> _loadOfflineDetail() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final offlineRoot = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}offline_anime',
    );

    if (!await offlineRoot.exists()) {
      throw Exception('Không tìm thấy dữ liệu anime đã tải xuống.');
    }

    String? animeTitle;
    String coverUrl = '';
    Directory? animeDirectory;

    await for (final entity in offlineRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final metadataFile = File(
        '${entity.path}${Platform.pathSeparator}metadata.json',
      );

      if (!await metadataFile.exists()) continue;

      try {
        final metadata = jsonDecode(await metadataFile.readAsString());

        if (metadata is! Map<String, dynamic>) continue;

        final savedAnimeUrl = metadata['animeUrl']?.toString() ?? '';

        if (savedAnimeUrl != widget.animeUrl) continue;

        animeTitle = metadata['animeTitle']?.toString() ?? '';
        coverUrl = metadata['coverUrl']?.toString() ?? '';
        animeDirectory = entity;
        break;
      } catch (e) {
        debugPrint('[OFFLINE ANIME] Cannot read metadata: $e');
      }
    }

    if (animeDirectory == null || animeTitle == null || animeTitle.isEmpty) {
      throw Exception('Anime này chưa được tải xuống hoặc dữ liệu đã bị xóa.');
    }

    final episodes = <AnimeEpisode>[];

    await for (final entity in animeDirectory.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final completeFile = File(
        '${entity.path}${Platform.pathSeparator}complete.json',
      );

      final videoFile = File(
        '${entity.path}${Platform.pathSeparator}video.mp4',
      );

      if (!await completeFile.exists() || !await videoFile.exists()) {
        continue;
      }

      try {
        final completeData = jsonDecode(await completeFile.readAsString());

        if (completeData is! Map<String, dynamic>) continue;
        if (completeData['completed'] != true) continue;

        final fileSize = await videoFile.length();
        if (fileSize <= 0) continue;

        final numberValue = completeData['episodeNumber'];
        final episodeNumber = numberValue is int
            ? numberValue
            : int.tryParse(numberValue?.toString() ?? '') ?? 0;

        final episodeUrl = completeData['episodeUrl']?.toString() ?? '';

        if (episodeNumber <= 0 || episodeUrl.isEmpty) continue;

        episodes.add(
          AnimeEpisode(
            number: episodeNumber,
            title: completeData['episodeTitle']?.toString() ?? '',
            url: episodeUrl,
            episodeId: completeData['episodeId']?.toString() ?? '',
          ),
        );
      } catch (e) {
        debugPrint('[OFFLINE ANIME] Cannot read episode: $e');
      }
    }

    episodes.sort((a, b) => a.number.compareTo(b.number));

    if (!mounted) return;

    final detail = AnimeDetail(
      title: animeTitle,
      cover: coverUrl,
      description: '',
      status: '',
      year: '',
      type: '',
      genres: const [],
      studios: const [],
      episodes: episodes,
    );

    final downloadedStates = <String, bool>{};

    for (final episode in episodes) {
      final downloadId = _downloadService.createDownloadId(
        detail.title,
        widget.animeUrl,
        episode,
      );

      downloadedStates[downloadId] = true;
    }

    setState(() {
      _detail = detail;
      _parts = [];
      _selectedPartName = null;
      _downloadedEpisodes
        ..clear()
        ..addAll(downloadedStates);
      _loading = false;
    });
  }

  Future<void> _loadParts() async {
    try {
      final parts = await _animeService.getParts(widget.animeUrl);

      if (!mounted) return;

      final matchingParts =
      parts.where((part) => part.url == widget.animeUrl);

      setState(() {
        _parts = parts;

        if (matchingParts.isNotEmpty) {
          _selectedPartName = matchingParts.first.name;
        } else if (parts.isNotEmpty) {
          _selectedPartName = parts.first.name;
        } else {
          _selectedPartName = null;
        }
      });
    } catch (e) {
      debugPrint('Error loading anime parts: $e');
    }
  }

  Future<void> _loadDownloadStates(AnimeDetail detail) async {
    await Future.wait(
      detail.episodes.map((episode) async {
        final downloadId = _downloadService.createDownloadId(
          detail.title,
          widget.animeUrl,
          episode,
        );

        try {
          final downloaded = await _downloadService.isEpisodeDownloaded(
            animeTitle: detail.title,
            animeUrl: widget.animeUrl,
            episode: episode,
          );

          if (!mounted) return;

          setState(() {
            _downloadedEpisodes[downloadId] = downloaded;
          });
        } catch (e) {
          debugPrint('Error checking downloaded episode: $e');
        }
      }),
    );
  }

  void _onPartChanged(AnimePartDTO part) {
    if (_isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không thể chuyển phần/mùa khi đang offline.'),
        ),
      );
      return;
    }

    if (part.url == widget.animeUrl) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AnimeDetailScreen(animeUrl: part.url),
      ),
    );
  }

  void _openPlayer(int episodeIndex) {
    if (_detail == null || _detail!.episodes.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimePlayerMediaKitScreen(
          animeTitle: _detail!.title,
          animeUrl: widget.animeUrl,
          episodes: _detail!.episodes,
          initialEpisodeIndex: episodeIndex,
          parts: _parts,
          currentPartName: _selectedPartName,
        ),
      ),
    );
  }

  Future<void> _downloadEpisode(AnimeEpisode episode) async {
    if (_isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không thể tải tập phim khi đang offline.'),
        ),
      );
      return;
    }

    final detail = _detail;
    if (detail == null) return;

    final downloadId = _downloadService.createDownloadId(
      detail.title,
      widget.animeUrl,
      episode,
    );

    if (_downloadedEpisodes[downloadId] == true ||
        _checkingDownloads.contains(downloadId) ||
        _downloadService.isDownloading(downloadId)) {
      return;
    }

    setState(() {
      _checkingDownloads.add(downloadId);
    });

    try {
      final alreadyDownloaded =
      await _downloadService.isEpisodeDownloaded(
        animeTitle: detail.title,
        animeUrl: widget.animeUrl,
        episode: episode,
      );

      if (!mounted) return;

      setState(() {
        _checkingDownloads.remove(downloadId);

        if (alreadyDownloaded) {
          _downloadedEpisodes[downloadId] = true;
        }
      });

      if (alreadyDownloaded) return;

      await _downloadService.downloadEpisode(
        animeTitle: detail.title,
        animeUrl: widget.animeUrl,
        episode: episode,
        animeService: _animeService,
        coverUrl: detail.cover,
      );

      if (!mounted) return;

      setState(() {
        _downloadedEpisodes[downloadId] = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã tải xong tập ${episode.number}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lỗi tải tập ${episode.number}: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted && _checkingDownloads.contains(downloadId)) {
        setState(() {
          _checkingDownloads.remove(downloadId);
        });
      }
    }
  }

  void _pauseDownload(String downloadId) {
    _downloadService.pauseDownload(downloadId);
  }

  void _resumeDownload(String downloadId) {
    _downloadService.resumeDownload(downloadId);
  }

  Future<void> _cancelDownload(String downloadId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hủy tải xuống?'),
        content: const Text(
          'Bạn có chắc chắn muốn hủy tải tập này không?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Không'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hủy tải'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _downloadService.cancelDownload(downloadId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chi tiết Anime')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chi tiết Anime')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Lỗi: $_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _loadDetail,
                  child: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_detail == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chi tiết Anime')),
        body: const Center(
          child: Text('Không tìm thấy thông tin anime'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _detail!.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                if (_parts.isNotEmpty) _buildPartsChips(),
                _buildEpisodesList(),
                _buildMetaInfo(),
                _buildDescription(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final cover = _detail!.cover;

    return Container(
      height: 220,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Stack(
        children: [
          if (cover.isNotEmpty)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: cover,
                fit: BoxFit.cover,
                placeholder: (_, __) =>
                const Center(child: CircularProgressIndicator()),
                errorWidget: (_, __, ___) =>
                const Icon(Icons.broken_image, size: 64),
              ),
            ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.7),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (cover.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: cover,
                      width: 100,
                      height: 150,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        width: 100,
                        height: 150,
                        color: Colors.grey[800],
                        child: const Center(
                          child: CircularProgressIndicator(),
                        ),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 100,
                        height: 150,
                        color: Colors.grey[800],
                        child: const Icon(Icons.broken_image, size: 40),
                      ),
                    ),
                  )
                else
                  Container(
                    width: 100,
                    height: 150,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.movie,
                      size: 40,
                      color: Colors.white54,
                    ),
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _detail!.title,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      _buildMetaChips(),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _detail!.episodes.isNotEmpty
                            ? () => _openPlayer(0)
                            : null,
                        icon: const Icon(Icons.play_circle_fill),
                        label: const Text('Xem ngay'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartsChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Phần / Mùa (${_parts.length})',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _parts.map((part) {
                final isSelected =
                    _selectedPartName == part.name &&
                        part.url == widget.animeUrl;

                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(part.name),
                    selected: isSelected,
                    onSelected: (_) => _onPartChanged(part),
                    selectedColor:
                    Theme.of(context).colorScheme.primaryContainer,
                    labelStyle: TextStyle(
                      color: isSelected
                          ? Theme.of(context)
                          .colorScheme
                          .onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurface,
                      fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                    ),
                    showCheckmark: false,
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaChips() {
    final chips = <Widget>[];

    if (_detail!.status.isNotEmpty) {
      chips.add(
        _MetaChip(
          icon: _detail!.status.contains('Hoàn')
              ? Icons.check_circle
              : Icons.schedule,
          label: _detail!.status,
          color: _detail!.status.contains('Hoàn')
              ? Colors.green
              : Colors.orange,
        ),
      );
    }

    if (_detail!.year.isNotEmpty) {
      chips.add(
        _MetaChip(
          icon: Icons.calendar_today,
          label: _detail!.year,
        ),
      );
    }

    if (_detail!.type.isNotEmpty) {
      chips.add(
        _MetaChip(
          icon: Icons.category,
          label: _detail!.type,
        ),
      );
    }

    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }

  Widget _buildEpisodesList() {
    final episodes = _detail!.episodes;

    if (episodes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Anime này chưa có tập nào được tải xuống.'),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Danh sách tập (${episodes.length})',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(episodes.length, (index) {
                final episode = episodes[index];

                final downloadId = _downloadService.createDownloadId(
                  _detail!.title,
                  widget.animeUrl,
                  episode,
                );

                return _EpisodeDownloadItem(
                  episode: episode,
                  downloadId: downloadId,
                  downloadService: _downloadService,
                  isDownloaded: _downloadedEpisodes[downloadId] == true,
                  isChecking: _checkingDownloads.contains(downloadId),
                  onTap: () => _openPlayer(index),
                  onDownload: () => _downloadEpisode(episode),
                  onPause: () => _pauseDownload(downloadId),
                  onResume: () => _resumeDownload(downloadId),
                  onCancel: () => _cancelDownload(downloadId),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaInfo() {
    if (_detail!.genres.isEmpty && _detail!.studios.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_detail!.genres.isNotEmpty) ...[
            Text(
              'Thể loại',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _detail!.genres
                  .map(
                    (genre) => Chip(
                  label: Text(genre),
                  backgroundColor:
                  Theme.of(context).colorScheme.secondaryContainer,
                ),
              )
                  .toList(),
            ),
            const SizedBox(height: 16),
          ],
          if (_detail!.studios.isNotEmpty) ...[
            Text(
              'Studio',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _detail!.studios
                  .map((studio) => Chip(label: Text(studio)))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDescription() {
    if (_detail!.description.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nội dung',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _detail!.description,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _EpisodeDownloadItem extends StatelessWidget {
  final AnimeEpisode episode;
  final String downloadId;
  final AnimeDownloadService downloadService;
  final bool isDownloaded;
  final bool isChecking;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  const _EpisodeDownloadItem({
    required this.episode,
    required this.downloadId,
    required this.downloadService,
    required this.isDownloaded,
    required this.isChecking,
    required this.onTap,
    required this.onDownload,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  Widget _buildProgressIndicator(
      BuildContext context,
      AnimeDownloadProgress progress,
      ) {
    final colorScheme = Theme.of(context).colorScheme;

    final isMerging = progress.status.contains('ghép video');
    final hasProgress = progress.total > 0 && !isMerging;
    final percentage = hasProgress ? progress.percent : null;

    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 25,
            height: 25,
            child: CircularProgressIndicator(
              value: hasProgress ? progress.progress : null,
              strokeWidth: 2.5,
              backgroundColor: colorScheme.outlineVariant,
              valueColor: AlwaysStoppedAnimation<Color>(
                progress.isPaused
                    ? colorScheme.tertiary
                    : colorScheme.primary,
              ),
            ),
          ),
          if (percentage != null)
            Text(
              '$percentage',
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            )
          else
            Icon(
              progress.isPaused ? Icons.pause : Icons.downloading,
              size: 13,
              color: progress.isPaused
                  ? colorScheme.tertiary
                  : colorScheme.primary,
            ),
        ],
      ),
    );
  }

  Widget _buildDownloadButton(
      BuildContext context,
      AnimeDownloadProgress progress,
      ) {
    final colorScheme = Theme.of(context).colorScheme;

    final isActive = progress.isDownloading || progress.isPaused;
    final completed = isDownloaded || progress.isCompleted;

    if (completed) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Icon(
          Icons.check_circle,
          color: Colors.green,
          size: 21,
        ),
      );
    }

    if (isChecking) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 19,
            height: 19,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (isActive) {
      return PopupMenuButton<String>(
        tooltip: progress.status.isEmpty
            ? 'Đang tải'
            : '${progress.status} '
            '${progress.total > 0 ? '${progress.percent}%' : ''}',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        icon: _buildProgressIndicator(context, progress),
        onSelected: (value) {
          if (value == 'pause') onPause();
          if (value == 'resume') onResume();
          if (value == 'cancel') onCancel();
        },
        itemBuilder: (context) => [
          if (progress.isPaused)
            const PopupMenuItem(
              value: 'resume',
              child: ListTile(
                leading: Icon(Icons.play_arrow),
                title: Text('Tiếp tục tải'),
                contentPadding: EdgeInsets.zero,
              ),
            )
          else
            const PopupMenuItem(
              value: 'pause',
              child: ListTile(
                leading: Icon(Icons.pause),
                title: Text('Tạm dừng'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          const PopupMenuItem(
            value: 'cancel',
            child: ListTile(
              leading: Icon(Icons.close),
              title: Text('Hủy tải'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      );
    }

    if (progress.error != null) {
      return IconButton(
        tooltip: 'Tải lỗi. Nhấn để thử lại',
        visualDensity: VisualDensity.compact,
        onPressed: onDownload,
        icon: const Icon(
          Icons.error_outline,
          color: Colors.red,
          size: 21,
        ),
      );
    }

    return IconButton(
      tooltip: 'Tải xuống',
      visualDensity: VisualDensity.compact,
      onPressed: onDownload,
      icon: Icon(
        Icons.download,
        color: colorScheme.primary,
        size: 21,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AnimeDownloadProgress>(
      valueListenable: downloadService.progressFor(downloadId),
      builder: (context, progress, _) {
        final colorScheme = Theme.of(context).colorScheme;

        return Container(
          constraints: const BoxConstraints(minWidth: 100),
          padding: const EdgeInsets.only(left: 8, right: 4),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_arrow_rounded,
                        size: 18,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        episode.number.toString(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 3),
              _buildDownloadButton(context, progress),
            ],
          ),
        );
      },
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _MetaChip({
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final chipColor = color ?? Theme.of(context).colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: chipColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: chipColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: chipColor,
            ),
          ),
        ],
      ),
    );
  }
}
