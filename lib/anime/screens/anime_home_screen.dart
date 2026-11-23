
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/anime_service.dart';
import '../services/anime_offline_library_service.dart';
import '../../offline/service/offline_mode_service.dart';
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

  final AnimeOfflineLibraryService _offlineLibraryService =
      AnimeOfflineLibraryService.instance;

  final TextEditingController _offlineSearchController =
  TextEditingController();

  List<AnimeSearchResult> _recentAnime = [];
  List<AnimeSearchResult> _downloadedAnime = [];

  AnimeFilterMetadata? _filterMetadata;

  bool _loading = true;
  bool _isOffline = OfflineModeService.isOffline.value;

  String? _error;
  String _offlineSearchQuery = '';

  int _loadRequestId = 0;

  @override
  void initState() {
    super.initState();

    OfflineModeService.isOffline.addListener(_onOfflineModeChanged);

    _loadInitialData();
  }

  @override
  void dispose() {
    OfflineModeService.isOffline.removeListener(_onOfflineModeChanged);
    _offlineSearchController.dispose();

    super.dispose();
  }

  void _onOfflineModeChanged() {
    if (!mounted) return;

    final offline = OfflineModeService.isOffline.value;

    if (_isOffline == offline) return;

    setState(() {
      _isOffline = offline;
      _offlineSearchQuery = '';
      _offlineSearchController.clear();
    });

    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final requestId = ++_loadRequestId;
    final offline = _isOffline;

    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (offline) {
        final downloadedAnime =
        await _offlineLibraryService.getDownloadedAnime();

        if (!mounted || requestId != _loadRequestId) return;

        setState(() {
          _downloadedAnime = downloadedAnime;
          _loading = false;
          _error = null;
        });

        return;
      }

      final results = await Future.wait([
        _animeService.getRecent(page: 1),
        _animeService.getFilters(),
      ]);

      if (!mounted || requestId != _loadRequestId) return;

      setState(() {
        _recentAnime = results[0] as List<AnimeSearchResult>;
        _filterMetadata = results[1] as AnimeFilterMetadata;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestId != _loadRequestId) return;

      setState(() {
        _error = _getFriendlyErrorMessage(e);
        _loading = false;
      });
    }
  }

  String _getFriendlyErrorMessage(Object error) {
    if (error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException) {
      return 'Không có kết nối Internet. Vui lòng kiểm tra mạng và thử lại.';
    }

    if (error is HttpException) {
      return 'Không thể kết nối đến máy chủ. Vui lòng thử lại sau.';
    }

    if (error is FormatException) {
      return 'Dữ liệu nhận được không hợp lệ. Vui lòng thử lại sau.';
    }

    final message = error.toString().toLowerCase();

    if (message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('network is unreachable') ||
        message.contains('connection refused') ||
        message.contains('connection reset') ||
        message.contains('no internet') ||
        message.contains('network error')) {
      return 'Không có kết nối Internet. Vui lòng kiểm tra mạng và thử lại.';
    }

    if (message.contains('timeout') ||
        message.contains('timed out')) {
      return 'Kết nối quá thời gian chờ. Vui lòng thử lại.';
    }

    if (message.contains('404')) {
      return 'Không tìm thấy dữ liệu yêu cầu.';
    }

    if (message.contains('500') ||
        message.contains('502') ||
        message.contains('503') ||
        message.contains('504')) {
      return 'Máy chủ đang gặp sự cố. Vui lòng thử lại sau.';
    }

    return 'Không thể tải dữ liệu. Vui lòng thử lại sau.';
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AnimeSearchScreen(),
      ),
    );
  }

  void _openAnime(AnimeSearchResult anime) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimeDetailScreen(
          animeUrl: anime.url,
        ),
      ),
    ).then((_) {
      if (_isOffline) {
        _loadInitialData();
      }
    });
  }

  List<AnimeSearchResult> get _filteredDownloadedAnime {
    final query = _offlineSearchQuery.trim().toLowerCase();

    if (query.isEmpty) {
      return _downloadedAnime;
    }

    return _downloadedAnime.where((anime) {
      return anime.name.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isOffline ? 'Anime đã tải' : 'Anime'),
        actions: [
          if (!_isOffline)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Tìm kiếm anime',
              onPressed: _openSearch,
            ),
        ],
      ),
      body: _isOffline ? _buildOfflineBody() : _buildOnlineBody(),
    );
  }

  // OFFLINE

  Widget _buildOfflineBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return _buildErrorState();
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            controller: _offlineSearchController,
            onChanged: (value) {
              setState(() {
                _offlineSearchQuery = value;
              });
            },
            decoration: InputDecoration(
              hintText: 'Tìm anime đã tải...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _offlineSearchQuery.isNotEmpty
                  ? IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Xóa tìm kiếm',
                onPressed: () {
                  _offlineSearchController.clear();

                  setState(() {
                    _offlineSearchQuery = '';
                  });
                },
              )
                  : null,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadInitialData,
            child: _buildDownloadedAnimeGrid(),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadedAnimeGrid() {
    final animeList = _filteredDownloadedAnime;

    if (animeList.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.35,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.video_library_outlined,
                    size: 56,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _downloadedAnime.isEmpty
                        ? 'Chưa có anime nào được tải xuống.'
                        : 'Không tìm thấy anime phù hợp.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: animeList.length,
      itemBuilder: (context, index) {
        final anime = animeList[index];

        return AnimeCard(
          anime: anime,
          onTap: () => _openAnime(anime),
        );
      },
    );
  }

  // ONLINE

  Widget _buildOnlineBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return _buildErrorState();
    }

    return RefreshIndicator(
      onRefresh: _loadInitialData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('Mới cập nhật'),
            _buildRecentList(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
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
          onTap: () => _openAnime(anime),
        );
      },
    );
  }

  // ERROR

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? 'Đã xảy ra lỗi.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadInitialData,
              child: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}
