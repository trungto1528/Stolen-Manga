import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/anime_service.dart';
import '../models/anime.dart';
import '../widgets/anime_card.dart';
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Lỗi: $_error'),
              ElevatedButton(
                onPressed: _loadDetail,
                child: const Text('Thử lại'),
              ),
            ],
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
        title: Text(_detail!.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _buildHeader(),
          ),
          SliverToBoxAdapter(
            child: _buildMetaInfo(),
          ),
          SliverToBoxAdapter(
            child: _buildDescription(),
          ),
          SliverToBoxAdapter(
            child: _buildEpisodesList(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cover image
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImage(
              imageUrl: _detail!.cover,
              width: 120,
              height: 160,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: 120,
                height: 160,
                color: Colors.grey[300],
                child: const Center(child: CircularProgressIndicator()),
              ),
              errorWidget: (_, __, ___) => Container(
                width: 120,
                height: 160,
                color: Colors.grey[300],
                child: const Icon(Icons.image_not_supported, size: 40),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _detail!.title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                _buildMetaChips(),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () {
                    if (_detail!.episodes.isNotEmpty) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
builder: (_) => AnimePlayerMediaKitScreen(
                            animeTitle: _detail!.title,
                            episodes: _detail!.episodes,
                            initialEpisodeIndex: 0,
                          ),
                        ),
                      );
                    }
                  },
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
    );
  }

  Widget _buildMetaChips() {
    final chips = <Widget>[];

    if (_detail!.status.isNotEmpty) {
      chips.add(_MetaChip(
        icon: _detail!.status.contains('Hoàn') ? Icons.check_circle : Icons.schedule,
        label: _detail!.status,
        color: _detail!.status.contains('Hoàn') ? Colors.green : Colors.orange,
      ));
    }

    if (_detail!.year.isNotEmpty) {
      chips.add(_MetaChip(
        icon: Icons.calendar_today,
        label: _detail!.year,
      ));
    }

    if (_detail!.type.isNotEmpty) {
      chips.add(_MetaChip(
        icon: Icons.category,
        label: _detail!.type,
      ));
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: chips,
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
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _detail!.genres
                  .map((g) => Chip(
                        label: Text(g),
                        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
          ],
          if (_detail!.studios.isNotEmpty) ...[
            Text(
              'Studio',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _detail!.studios
                  .map((s) => Chip(label: Text(s)))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDescription() {
    if (_detail!.description.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nội dung',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
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

  Widget _buildEpisodesList() {
    if (_detail!.episodes.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Danh sách tập (${_detail!.episodes.length})',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _detail!.episodes.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final episode = _detail!.episodes[index];
              return _EpisodeTile(
                episode: episode,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
builder: (_) => AnimePlayerMediaKitScreen(
                        animeTitle: _detail!.title,
                        episodes: _detail!.episodes,
                        initialEpisodeIndex: index,
                      ),
                    ),
                  );
                },
              );
            },
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

  const _MetaChip({
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: (color ?? Theme.of(context).colorScheme.primary).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color ?? Theme.of(context).colorScheme.primary,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color ?? Theme.of(context).colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color ?? Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final AnimeEpisode episode;
  final VoidCallback onTap;

  const _EpisodeTile({
    required this.episode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            'T${episode.number}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          episode.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('Tập ${episode.number}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
