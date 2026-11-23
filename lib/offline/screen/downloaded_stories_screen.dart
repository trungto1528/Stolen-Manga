
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:novel_app/offline/service/story_download_service.dart';
import 'package:path_provider/path_provider.dart';

class DownloadedStory {
  final int id;
  final String title;
  final String author;
  final String directoryPath;
  final String? coverPath;
  final int imageCount;
  final int sizeBytes;
  final DateTime? downloadedAt;

  const DownloadedStory({
    required this.id,
    required this.title,
    required this.author,
    required this.directoryPath,
    required this.coverPath,
    required this.imageCount,
    required this.sizeBytes,
    required this.downloadedAt,
  });

  String get formattedSize => _formatSize(sizeBytes);
}

class DownloadedAnime {
  final String title;
  final String animeUrl;
  final String directoryPath;
  final String? coverUrl;
  final String? coverPath;
  final int episodeCount;
  final int sizeBytes;
  final DateTime? downloadedAt;

  const DownloadedAnime({
    required this.title,
    required this.animeUrl,
    required this.directoryPath,
    required this.coverUrl,
    required this.coverPath,
    required this.episodeCount,
    required this.sizeBytes,
    required this.downloadedAt,
  });

  String get formattedSize => _formatSize(sizeBytes);
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';

  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';

  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';

  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class DownloadedStoriesScreen extends StatefulWidget {
  const DownloadedStoriesScreen({super.key});

  @override
  State<DownloadedStoriesScreen> createState() =>
      _DownloadedStoriesScreenState();
}

class _DownloadedStoriesScreenState extends State<DownloadedStoriesScreen> {
  List<DownloadedStory> _stories = [];
  List<DownloadedAnime> _anime = [];

  bool _loadingStories = true;
  bool _loadingAnime = true;

  String? _storyError;
  String? _animeError;

  int _totalStorySize = 0;
  int _totalAnimeSize = 0;

  @override
  void initState() {
    super.initState();
    _loadDownloadedStories();
    _loadDownloadedAnime();
  }

  Future<Directory> _getOfflineRoot(String folder) async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/$folder');
  }

  Future<int> _calculateDirectorySize(Directory directory) async {
    var total = 0;

    if (!await directory.exists()) return total;

    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // Bỏ qua file không thể đọc.
        }
      }
    }

    return total;
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Không rõ ngày tải';

    final local = date.toLocal();

    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${twoDigits(local.day)}/${twoDigits(local.month)}/'
        '${local.year} ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  // ---------------------------------------------------------------------------
  // MANGA
  // ---------------------------------------------------------------------------

  Future<List<DownloadedStory>> _scanDownloadedStories() async {
    final root = await _getOfflineRoot('offline_stories');

    if (!await root.exists()) return [];

    final result = <DownloadedStory>[];

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final storyId = int.tryParse(
        entity.path.split(Platform.pathSeparator).last,
      );

      if (storyId == null) continue;

      final completeFile = File('${entity.path}/complete.json');
      final metadataFile = File('${entity.path}/metadata.json');

      if (!await completeFile.exists() ||
          !await metadataFile.exists()) {
        continue;
      }

      try {
        final manifestJson = jsonDecode(
          await completeFile.readAsString(),
        );

        final metadataJson = jsonDecode(
          await metadataFile.readAsString(),
        );

        if (manifestJson is! Map || metadataJson is! Map) {
          continue;
        }

        if (manifestJson['storyId'] != null &&
            int.tryParse(manifestJson['storyId'].toString()) != storyId) {
          continue;
        }

        final title = metadataJson['title']?.toString().trim();
        final author = metadataJson['author']?.toString().trim() ?? '';

        final images = manifestJson['images'] is List
            ? List<String>.from(
          (manifestJson['images'] as List).map(
                (item) => item.toString(),
          ),
        )
            : <String>[];

        String? coverPath;

        for (final image in images) {
          if (image.replaceAll('\\', '/').startsWith('cover/')) {
            final normalized = image.replaceAll(
              '/',
              Platform.pathSeparator,
            );

            final file = File('${entity.path}/$normalized');

            if (await file.exists() && await file.length() > 0) {
              coverPath = file.path;
              break;
            }
          }
        }

        final downloadedAtText =
        manifestJson['downloadedAt']?.toString();

        final downloadedAt = downloadedAtText == null
            ? null
            : DateTime.tryParse(downloadedAtText);

        final size = await _calculateDirectorySize(entity);

        result.add(
          DownloadedStory(
            id: storyId,
            title: title == null || title.isEmpty
                ? 'Truyện #$storyId'
                : title,
            author: author,
            directoryPath: entity.path,
            coverPath: coverPath,
            imageCount: images.length,
            sizeBytes: size,
            downloadedAt: downloadedAt,
          ),
        );
      } catch (e) {
        debugPrint('Không đọc được dữ liệu truyện $storyId: $e');
      }
    }

    result.sort((a, b) {
      final dateA = a.downloadedAt;
      final dateB = b.downloadedAt;

      if (dateA == null && dateB == null) {
        return a.title.compareTo(b.title);
      }

      if (dateA == null) return 1;
      if (dateB == null) return -1;

      return dateB.compareTo(dateA);
    });

    return result;
  }

  Future<void> _loadDownloadedStories() async {
    if (mounted) {
      setState(() {
        _loadingStories = true;
        _storyError = null;
      });
    }

    try {
      final stories = await _scanDownloadedStories();

      if (!mounted) return;

      setState(() {
        _stories = stories;
        _totalStorySize = stories.fold<int>(
          0,
              (total, story) => total + story.sizeBytes,
        );
        _loadingStories = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _storyError = e.toString();
        _loadingStories = false;
      });
    }
  }

  Future<void> _deleteStory(DownloadedStory story) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa truyện đã tải?'),
        content: Text(
          'Bạn có chắc muốn xóa "${story.title}" khỏi thiết bị?\n\n'
              'Dung lượng sẽ được giải phóng: ${story.formattedSize}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await StoryDownloadService.instance.deleteDownloadedStory(
        story.id,
      );

      await _loadDownloadedStories();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã xóa "${story.title}"')),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể xóa truyện: $e')),
      );
    }
  }

  Future<void> _deleteAllStories() async {
    if (_stories.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa tất cả truyện offline?'),
        content: Text(
          'Sẽ xóa ${_stories.length} truyện, giải phóng khoảng '
              '${_formatSize(_totalStorySize)}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xóa tất cả'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    var deletedCount = 0;
    final errors = <String>[];

    for (final story in List<DownloadedStory>.from(_stories)) {
      try {
        await StoryDownloadService.instance.deleteDownloadedStory(
          story.id,
        );
        deletedCount++;
      } catch (e) {
        errors.add('${story.title}: $e');
      }
    }

    await _loadDownloadedStories();

    if (!mounted) return;

    final message = errors.isEmpty
        ? 'Đã xóa $deletedCount truyện'
        : 'Đã xóa $deletedCount truyện; còn ${errors.length} truyện chưa xóa được';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ---------------------------------------------------------------------------
  // ANIME
  // ---------------------------------------------------------------------------

  Future<String?> _ensureAnimeCover({
    required String directoryPath,
    required String? coverUrl,
  }) async {
    final coverFile = File(
      '$directoryPath${Platform.pathSeparator}cover.jpg',
    );

    // Ưu tiên ảnh đã lưu trên thiết bị.
    if (await coverFile.exists()) {
      try {
        if (await coverFile.length() > 0) {
          return coverFile.path;
        }
      } catch (_) {
        // Nếu file lỗi thì thử tải lại.
      }
    }

    if (coverUrl == null || coverUrl.trim().isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(coverUrl.trim());

    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final temporaryFile = File('$directoryPath${Platform.pathSeparator}cover.tmp');

    try {
      final response = await http.get(uri).timeout(
        const Duration(seconds: 15),
      );

      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }

      await temporaryFile.writeAsBytes(
        response.bodyBytes,
        flush: true,
      );

      if (await coverFile.exists()) {
        await coverFile.delete();
      }

      await temporaryFile.rename(coverFile.path);

      return coverFile.path;
    } catch (e) {
      debugPrint('Không thể tải cover anime từ $coverUrl: $e');

      try {
        if (await temporaryFile.exists()) {
          await temporaryFile.delete();
        }
      } catch (_) {}

      return null;
    }
  }

  Future<List<DownloadedAnime>> _scanDownloadedAnime() async {
    final root = await _getOfflineRoot('offline_anime');

    if (!await root.exists()) return [];

    final result = <DownloadedAnime>[];

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final metadataFile = File('${entity.path}/metadata.json');

      if (!await metadataFile.exists()) continue;

      try {
        final metadataJson = jsonDecode(
          await metadataFile.readAsString(),
        );

        if (metadataJson is! Map) continue;

        final title = metadataJson['animeTitle']?.toString().trim();
        final animeUrl = metadataJson['animeUrl']?.toString().trim();

        if (title == null ||
            title.isEmpty ||
            animeUrl == null ||
            animeUrl.isEmpty) {
          continue;
        }

        final coverUrl = metadataJson['coverUrl']?.toString();

        var episodeCount = 0;
        DateTime? latestDownloadedAt;

        await for (final episodeDirectory in entity.list(
          followLinks: false,
        )) {
          if (episodeDirectory is! Directory) continue;

          final directoryName = episodeDirectory.path
              .split(Platform.pathSeparator)
              .last;

          if (!directoryName.startsWith('episode_')) continue;

          final completeFile = File(
            '${episodeDirectory.path}/complete.json',
          );

          final videoFile = File(
            '${episodeDirectory.path}/video.mp4',
          );

          if (!await completeFile.exists() ||
              !await videoFile.exists()) {
            continue;
          }

          try {
            final marker = jsonDecode(
              await completeFile.readAsString(),
            );

            if (marker is! Map || marker['completed'] != true) {
              continue;
            }

            if (await videoFile.length() <= 0) continue;

            episodeCount++;

            final completedAtText =
            marker['completedAt']?.toString();

            final completedAt = completedAtText == null
                ? null
                : DateTime.tryParse(completedAtText);

            if (completedAt != null &&
                (latestDownloadedAt == null ||
                    completedAt.isAfter(latestDownloadedAt))) {
              latestDownloadedAt = completedAt;
            }
          } catch (e) {
            debugPrint(
              'Không đọc được tập anime ${episodeDirectory.path}: $e',
            );
          }
        }

        if (episodeCount == 0) continue;

        // Nếu chưa có cover.jpg, thử tải từ coverUrl và lưu lại.
        final coverPath = await _ensureAnimeCover(
          directoryPath: entity.path,
          coverUrl: coverUrl,
        );

        final size = await _calculateDirectorySize(entity);

        result.add(
          DownloadedAnime(
            title: title,
            animeUrl: animeUrl,
            directoryPath: entity.path,
            coverUrl: coverUrl,
            coverPath: coverPath,
            episodeCount: episodeCount,
            sizeBytes: size,
            downloadedAt: latestDownloadedAt,
          ),
        );
      } catch (e) {
        debugPrint('Không đọc được anime ${entity.path}: $e');
      }
    }

    result.sort((a, b) {
      final dateA = a.downloadedAt;
      final dateB = b.downloadedAt;

      if (dateA == null && dateB == null) {
        return a.title.compareTo(b.title);
      }

      if (dateA == null) return 1;
      if (dateB == null) return -1;

      return dateB.compareTo(dateA);
    });

    return result;
  }

  Future<void> _loadDownloadedAnime() async {
    if (mounted) {
      setState(() {
        _loadingAnime = true;
        _animeError = null;
      });
    }

    try {
      final anime = await _scanDownloadedAnime();

      if (!mounted) return;

      setState(() {
        _anime = anime;
        _totalAnimeSize = anime.fold<int>(
          0,
              (total, item) => total + item.sizeBytes,
        );
        _loadingAnime = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _animeError = e.toString();
        _loadingAnime = false;
      });
    }
  }

  Future<void> _deleteAnime(DownloadedAnime anime) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa anime đã tải?'),
        content: Text(
          'Bạn có chắc muốn xóa "${anime.title}" khỏi thiết bị?\n\n'
              'Số tập: ${anime.episodeCount}\n'
              'Dung lượng giải phóng: ${anime.formattedSize}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await Directory(anime.directoryPath).delete(recursive: true);

      await _loadDownloadedAnime();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã xóa "${anime.title}"')),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể xóa anime: $e')),
      );
    }
  }

  Future<void> _deleteAllAnime() async {
    if (_anime.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa tất cả anime đã tải?'),
        content: Text(
          'Sẽ xóa ${_anime.length} anime, giải phóng khoảng '
              '${_formatSize(_totalAnimeSize)}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xóa tất cả'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    var deletedCount = 0;
    final errors = <String>[];

    for (final anime in List<DownloadedAnime>.from(_anime)) {
      try {
        await Directory(anime.directoryPath).delete(recursive: true);
        deletedCount++;
      } catch (e) {
        errors.add('${anime.title}: $e');
      }
    }

    await _loadDownloadedAnime();

    if (!mounted) return;

    final message = errors.isEmpty
        ? 'Đã xóa $deletedCount anime'
        : 'Đã xóa $deletedCount anime; còn ${errors.length} anime chưa xóa được';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ---------------------------------------------------------------------------
  // SHARED WIDGETS
  // ---------------------------------------------------------------------------

  Widget _buildSummary({
    required String title,
    required int count,
    required int totalSize,
    required VoidCallback onDeleteAll,
  }) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.storage_outlined, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$count $title đã tải',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Đang sử dụng ${_formatSize(totalSize)} bộ nhớ',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            if (count > 0)
              IconButton(
                tooltip: 'Xóa tất cả',
                onPressed: onDeleteAll,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(icon, size: 72),
        const SizedBox(height: 16),
        Center(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              description,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState({
    required String message,
    required String title,
    required VoidCallback onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(title),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // MANGA UI
  // ---------------------------------------------------------------------------

  Widget _buildMangaCover(DownloadedStory story) {
    final path = story.coverPath;

    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildMangaCoverPlaceholder(),
      );
    }

    return _buildMangaCoverPlaceholder();
  }

  Widget _buildMangaCoverPlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.menu_book_rounded, size: 38),
      ),
    );
  }

  Widget _buildStoryCard(DownloadedStory story) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 84,
                height: 116,
                child: _buildMangaCover(story),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    story.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (story.author.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      'Tác giả: ${story.author}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 7),
                  Text('${story.imageCount} ảnh'),
                  Text(story.formattedSize),
                  const SizedBox(height: 4),
                  Text(
                    _formatDate(story.downloadedAt),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Xóa bản tải',
              onPressed: () => _deleteStory(story),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMangaTab() {
    if (_loadingStories) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_storyError != null) {
      return _buildErrorState(
        title: 'Không thể đọc danh sách truyện đã tải',
        message: _storyError!,
        onRetry: _loadDownloadedStories,
      );
    }

    if (_stories.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadDownloadedStories,
        child: _buildEmptyState(
          icon: Icons.download_for_offline_outlined,
          title: 'Chưa có manga nào được tải',
          description: 'Những truyện tải hoàn tất sẽ xuất hiện tại đây.',
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDownloadedStories,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _buildSummary(
            title: 'manga',
            count: _stories.length,
            totalSize: _totalStorySize,
            onDeleteAll: _deleteAllStories,
          ),
          ..._stories.map(_buildStoryCard),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ANIME UI
  // ---------------------------------------------------------------------------

  Widget _buildAnimeCoverPlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(
          Icons.play_circle_outline,
          size: 42,
        ),
      ),
    );
  }

  Widget _buildAnimeCover(DownloadedAnime anime) {
    final path = anime.coverPath;

    if (path == null) {
      return _buildAnimeCoverPlaceholder();
    }

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _buildAnimeCoverPlaceholder(),
    );
  }

  Widget _buildAnimeCard(DownloadedAnime anime) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 84,
                height: 116,
                child: _buildAnimeCover(anime),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    anime.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text('${anime.episodeCount} tập đã tải'),
                  Text(anime.formattedSize),
                  const SizedBox(height: 4),
                  Text(
                    _formatDate(anime.downloadedAt),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Xóa anime đã tải',
              onPressed: () => _deleteAnime(anime),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimeTab() {
    if (_loadingAnime) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_animeError != null) {
      return _buildErrorState(
        title: 'Không thể đọc danh sách anime đã tải',
        message: _animeError!,
        onRetry: _loadDownloadedAnime,
      );
    }

    if (_anime.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadDownloadedAnime,
        child: _buildEmptyState(
          icon: Icons.movie_outlined,
          title: 'Chưa có anime nào được tải',
          description: 'Những anime có tập tải hoàn tất sẽ xuất hiện tại đây.',
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDownloadedAnime,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _buildSummary(
            title: 'anime',
            count: _anime.length,
            totalSize: _totalAnimeSize,
            onDeleteAll: _deleteAllAnime,
          ),
          ..._anime.map(_buildAnimeCard),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SCREEN
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Quản lý tải xuống'),
          actions: [
            IconButton(
              tooltip: 'Làm mới',
              onPressed: () {
                _loadDownloadedAnime();
                _loadDownloadedStories();
              },
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(
                icon: Icon(Icons.movie_outlined),
                text: 'Anime',
              ),
              Tab(
                icon: Icon(Icons.menu_book_outlined),
                text: 'Manga',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildAnimeTab(),
            _buildMangaTab(),
          ],
        ),
      ),
    );
  }
}
