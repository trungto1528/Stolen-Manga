import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/anime_service.dart';
import '../models/anime.dart';
import '../widgets/anime_card.dart';
import 'anime_detail_screen.dart';

class AnimeSearchScreen extends ConsumerStatefulWidget {
  const AnimeSearchScreen({super.key});

  @override
  ConsumerState<AnimeSearchScreen> createState() => _AnimeSearchScreenState();
}

class _AnimeSearchScreenState extends ConsumerState<AnimeSearchScreen> {
  final AnimeService _animeService = AnimeService();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  List<AnimeSearchResult> _results = [];
  AnimeFilterMetadata? _filterMetadata;
  bool _loading = false;
  bool _searching = false;
  String? _error;

  // Filter state
  List<int> _selectedCategories = [];
  List<int> _selectedYears = [];
  String? _selectedStatus;
  String _selectedSort = 'time';

  @override
  void initState() {
    super.initState();
    _loadFilters();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadFilters() async {
    try {
      final metadata = await _animeService.getFilters();
      if (!mounted) return;
      setState(() {
        _filterMetadata = metadata;
      });
    } catch (e) {
      // Ignore filter load errors
    }
  }

  Future<void> _search() async {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;

    _searchFocus.unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _results = [];
    });

    try {
      final results = await _animeService.searchAdvanced(
        keyword: keyword,
        categories: _selectedCategories.isEmpty ? null : _selectedCategories,
        years: _selectedYears.isEmpty ? null : _selectedYears,
        status: _selectedStatus?.isEmpty ?? true ? null : _selectedStatus,
        sort: _selectedSort,
      );

      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tìm kiếm Anime'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                hintText: 'Nhập tên anime...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _results = []);
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _buildResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // Categories
          if (_filterMetadata?.categories.isNotEmpty ?? false) ...[
            _FilterChipGroup(
              label: 'Thể loại',
              items: _filterMetadata!.categories
                  .map((c) => _FilterOption(
                        value: c.id,
                        label: c.name,
                        selected: _selectedCategories.contains(c.id),
                      ))
                  .toList(),
              onChanged: (selected) {
                setState(() {
                  _selectedCategories = selected.map((e) => e as int).toList();
                });
              },
              multiSelect: true,
            ),
            const SizedBox(width: 8),
          ],

          // Years
          if (_filterMetadata?.years.isNotEmpty ?? false) ...[
            _FilterChipGroup(
              label: 'Năm',
              items: _filterMetadata!.years
                  .map((y) => _FilterOption(
                        value: y.value,
                        label: y.label,
                        selected: _selectedYears.contains(y.value),
                      ))
                  .toList(),
              onChanged: (selected) {
                setState(() {
                  _selectedYears = selected.map((e) => e as int).toList();
                });
              },
              multiSelect: true,
            ),
            const SizedBox(width: 8),
          ],

          // Status
          if (_filterMetadata?.statuses.isNotEmpty ?? false) ...[
            _FilterChipGroup(
              label: 'Trạng thái',
              items: _filterMetadata!.statuses
                  .map((s) => _FilterOption(
                        value: s.value,
                        label: s.label,
                        selected: _selectedStatus == s.value,
                      ))
                  .toList(),
              onChanged: (selected) {
                setState(() {
                  _selectedStatus = selected.isEmpty ? null : selected.first as String;
                });
              },
              multiSelect: false,
            ),
            const SizedBox(width: 8),
          ],

          // Sort
          if (_filterMetadata?.sorts.isNotEmpty ?? false) ...[
            _FilterChipGroup(
              label: 'Sắp xếp',
              items: _filterMetadata!.sorts
                  .map((s) => _FilterOption(
                        value: s.value,
                        label: s.label,
                        selected: _selectedSort == s.value,
                      ))
                  .toList(),
              onChanged: (selected) {
                setState(() {
                  _selectedSort = selected.first as String;
                });
              },
              multiSelect: false,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Lỗi: $_error'),
            ElevatedButton(
              onPressed: _search,
              child: const Text('Thử lại'),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty && !_searching) {
      return const Center(
        child: Text('Không tìm thấy anime phù hợp'),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.65,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final anime = _results[index];
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

class _FilterOption {
  final dynamic value;
  final String label;
  final bool selected;

  _FilterOption({
    required this.value,
    required this.label,
    required this.selected,
  });
}

class _FilterChipGroup extends StatelessWidget {
  final String label;
  final List<_FilterOption> items;
  final void Function(List) onChanged;
  final bool multiSelect;

  const _FilterChipGroup({
    required this.label,
    required this.items,
    required this.onChanged,
    required this.multiSelect,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<List<dynamic>>(
      tooltip: label,
      onSelected: onChanged,
      itemBuilder: (context) {
        return items.map((item) {
          return CheckedPopupMenuItem<List<dynamic>>(
            value: multiSelect
                ? (() {
                    final current = items
                        .where((i) => i.selected)
                        .map((i) => i.value)
                        .toList();
                    if (item.selected) {
                      current.remove(item.value);
                    } else {
                      current.add(item.value);
                    }
                    return current;
                  })()
                : [item.value],
            enabled: true,
            checked: item.selected,
            child: Text(item.label),
          );
        }).toList();
      },
      child: Chip(
        label: Text(label),
        avatar: Icon(
          multiSelect ? Icons.check_box : Icons.radio_button_checked,
          size: 18,
        ),
        onDeleted: () => onChanged([]),
        deleteIcon: const Icon(Icons.clear, size: 16),
      ),
    );
  }
}
