import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/anime_part_dto.dart';
import '../models/anime.dart';
import '../services/anime_service.dart';
import 'anime_player_mediakit_screen.dart';

class AnimeDetailScreen extends ConsumerStatefulWidget {
  final String animeUrl;

  const AnimeDetailScreen({super.key, required this.animeUrl});

  @override
  ConsumerState<AnimeDetailScreen> createState() => _AnimeDetailScreenState();
}

class _AnimeDetailScreenState extends ConsumerState<AnimeDetailScreen> {
  final AnimeService _animeService = AnimeService();

  AnimeDetail? _detail;
  bool _loading = true;
  String? _error;

  List<AnimePartDTO> _parts = [];
  String? _selectedPartName;

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
      final detail = await _animeService.getDetail(widget.animeUrl);

      if (!mounted) return;

      setState(() {
        _detail = detail;
        _loading = false;
      });

      await _loadParts();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadParts() async {
    try {
      final parts = await _animeService.getParts(widget.animeUrl);

      if (!mounted) return;

      final matchingParts = parts.where((part) => part.url == widget.animeUrl);

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

  void _onPartChanged(AnimePartDTO part) {
    if (part.url == widget.animeUrl) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => AnimeDetailScreen(animeUrl: part.url)),
    );
  }

  void _openPlayer(int episodeIndex) {
    if (_detail == null || _detail!.episodes.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimePlayerMediaKitScreen(
          animeTitle: _detail!.title,
          episodes: _detail!.episodes,
          initialEpisodeIndex: episodeIndex,
          parts: _parts,
          currentPartName: _selectedPartName,
        ),
      ),
    );
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
        body: const Center(child: Text('Không tìm thấy thông tin anime')),
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
                        child: const Center(child: CircularProgressIndicator()),
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
                        style: Theme.of(context).textTheme.headlineSmall
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
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
                    selectedColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    labelStyle: TextStyle(
                      color: isSelected
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurface,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
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
      chips.add(_MetaChip(icon: Icons.calendar_today, label: _detail!.year));
    }

    if (_detail!.type.isNotEmpty) {
      chips.add(_MetaChip(icon: Icons.category, label: _detail!.type));
    }

    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }

  Widget _buildEpisodesList() {
    final episodes = _detail!.episodes;

    if (episodes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Anime này chưa có danh sách tập.'),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Danh sách tập (${episodes.length})',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(episodes.length, (index) {
                final episode = episodes[index];

                return _EpisodeChip(
                  episode: episode,
                  onTap: () => _openPlayer(index),
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
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _detail!.genres
                  .map(
                    (genre) => Chip(
                      label: Text(genre),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer,
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 16),
          ],
          if (_detail!.studios.isNotEmpty) ...[
            Text(
              'Studio',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _MetaChip({required this.icon, required this.label, this.color});

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

class _EpisodeChip extends StatelessWidget {
  final AnimeEpisode episode;
  final VoidCallback onTap;

  const _EpisodeChip({required this.episode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ActionChip(
      onPressed: onTap,
      avatar: Icon(
        Icons.play_arrow_rounded,
        size: 18,
        color: colorScheme.primary,
      ),
      label: Text(
        episode.number.toString(),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      backgroundColor: colorScheme.surfaceContainerHighest,
      side: BorderSide(color: colorScheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
