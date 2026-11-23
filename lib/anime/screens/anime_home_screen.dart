import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/anime_service.dart';
import '../models/anime.dart';
import '../widgets/anime_card.dart';
import 'anime_search_screen.dart';
import 'anime_detail_screen.dart';

class AnimeHomeScreen extends ConsumerStatefulWidget {
  const AnimeHomeScreen({super.key});

  @override
  ConsumerState<AnimeHomeScreen> createState() => _AnimeHomeScreenState();
}

class _AnimeHomeScreenState extends ConsumerState<AnimeHomeScreen> {
  final AnimeService _animeService = AnimeService();
  List<AnimeSearchResult> _recentAnime = [];
  AnimeFilterMetadata? _filterMetadata;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        _animeService.getRecent(page: 1),
        _animeService.getFilters(),
      ]);

      if (!mounted) return;
      setState(() {
        _recentAnime = results[0] as List<AnimeSearchResult>;
        _filterMetadata = results[1] as AnimeFilterMetadata;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Anime'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AnimeSearchScreen()),
              );
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Lỗi: $_error'),
            ElevatedButton(
              onPressed: _loadInitialData,
              child: const Text('Thử lại'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadInitialData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Recent anime
            _buildSectionHeader('Mới cập nhật', () {}),
            _buildRecentList(),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, VoidCallback onSeeAll) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildRecentList() {
    if (_recentAnime.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Không có anime mới cập nhật'),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: _recentAnime.length,
      itemBuilder: (context, index) {
        final anime = _recentAnime[index];
        return AnimeCard(
          anime: anime,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AnimeDetailScreen(animeUrl: anime.url),
              ),
            );
          },
        );
      },
    );
  }
}
