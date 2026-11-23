import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/api_config.dart';
import '../models/anime.dart';

class AnimeService {
  String get _baseUrl => ApiConfig.animeUrl;

  Map<String, dynamic> _decodeMap(
    String body, {
    String errorMessage = 'Dữ liệu trả về không hợp lệ',
  }) {
    final decoded = jsonDecode(body);

    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }

    throw FormatException(errorMessage);
  }

  List<dynamic> _decodeList(
    String body, {
    String errorMessage = 'Dữ liệu trả về không hợp lệ',
  }) {
    final decoded = jsonDecode(body);

    if (decoded is List) {
      return decoded;
    }

    throw FormatException(errorMessage);
  }

  Exception _httpError(String message, http.Response response) {
    String detail = response.body;

    try {
      final decoded = jsonDecode(response.body);

      if (decoded is Map) {
        detail = decoded['message']?.toString() ??
            decoded['error']?.toString() ??
            response.body;
      }
    } catch (_) {
      // Giữ nguyên response body nếu không phải JSON.
    }

    return Exception(
      '$message (HTTP ${response.statusCode}): $detail',
    );
  }

  // ============================================================
  // SEARCH ANIME
  // ============================================================

  Future<List<AnimeSearchResult>> search({
    required String keyword,
    int page = 1,
    int limit = 30,
  }) async {
    final uri = Uri.parse('$_baseUrl/search').replace(
      queryParameters: {
        'keyword': keyword.trim(),
        'page': page.toString(),
        'limit': limit.toString(),
      },
    );

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final decoded = _decodeList(
        res.body,
        errorMessage: 'Dữ liệu tìm kiếm không hợp lệ',
      );

      return decoded
          .map((item) => AnimeSearchResult.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    throw _httpError('Tìm kiếm thất bại', res);
  }

  Future<List<AnimeSearchResult>> searchAdvanced({
    String? keyword,
    List<int>? categories,
    List<int>? years,
    String? status,
    String? sort,
    int page = 1,
    int limit = 30,
  }) async {
    final queryParams = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
    };

    if (keyword != null && keyword.isNotEmpty) {
      queryParams['keyword'] = keyword.trim();
    }
    if (categories != null && categories.isNotEmpty) {
      queryParams['cates[]'] = categories.join(',');
    }
    if (years != null && years.isNotEmpty) {
      queryParams['years[]'] = years.join(',');
    }
    if (status != null && status.isNotEmpty) {
      queryParams['status'] = status;
    }
    if (sort != null && sort.isNotEmpty) {
      queryParams['sort'] = sort;
    }

    final uri = Uri.parse('$_baseUrl/filter').replace(
      queryParameters: queryParams,
    );

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final decoded = _decodeList(
        res.body,
        errorMessage: 'Dữ liệu tìm kiếm nâng cao không hợp lệ',
      );

      return decoded
          .map((item) => AnimeSearchResult.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    throw _httpError('Tìm kiếm nâng cao thất bại', res);
  }

  // ============================================================
  // ANIME DETAIL
  // ============================================================

  Future<AnimeDetail> getDetail(String animeUrl) async {
    final uri = Uri.parse('$_baseUrl/detail').replace(
      queryParameters: {'url': animeUrl},
    );

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      return AnimeDetail.fromJson(
        _decodeMap(res.body, errorMessage: 'Dữ liệu chi tiết anime không hợp lệ'),
      );
    }

    throw _httpError('Lấy chi tiết anime thất bại', res);
  }

  // ============================================================
  // EPISODES
  // ============================================================

  Future<List<AnimeEpisode>> getEpisodes(String animeUrl) async {
    final uri = Uri.parse('$_baseUrl/episodes').replace(
      queryParameters: {'animeUrl': animeUrl},
    );

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final decoded = _decodeList(
        res.body,
        errorMessage: 'Dữ liệu danh sách tập không hợp lệ',
      );

      return decoded
          .map((item) => AnimeEpisode.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    throw _httpError('Lấy danh sách tập thất bại', res);
  }

  // ============================================================
  // STREAM
  // ============================================================

  Future<AnimeStream> getStream(String episodeUrl) async {
    final uri = Uri.parse('$_baseUrl/stream').replace(
      queryParameters: {'episodeUrl': episodeUrl},
    );

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      return AnimeStream.fromJson(
        _decodeMap(res.body, errorMessage: 'Dữ liệu nguồn phát không hợp lệ'),
      );
    }

    throw _httpError('Lấy nguồn phát thất bại', res);
  }

  // ============================================================
  // RECENT
  // ============================================================

  Future<List<AnimeSearchResult>> getRecent({int page = 1}) async {
    final uri = Uri.parse('$_baseUrl/recent').replace(
      queryParameters: {'page': page.toString()},
    );

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final decoded = _decodeList(
        res.body,
        errorMessage: 'Dữ liệu anime mới cập nhật không hợp lệ',
      );

      return decoded
          .map((item) => AnimeSearchResult.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    throw _httpError('Lấy anime mới cập nhật thất bại', res);
  }

  // ============================================================
  // FILTERS
  // ============================================================

  Future<AnimeFilterMetadata> getFilters() async {
    final uri = Uri.parse('$_baseUrl/filters');

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      return AnimeFilterMetadata.fromJson(
        _decodeMap(res.body, errorMessage: 'Dữ liệu bộ lọc không hợp lệ'),
      );
    }

    throw _httpError('Lấy bộ lọc thất bại', res);
  }

  // ============================================================
  // PROVIDERS
  // ============================================================

  Future<List<String>> getProviders() async {
    final uri = Uri.parse('$_baseUrl/providers');

    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final decoded = _decodeList(
        res.body,
        errorMessage: 'Dữ liệu providers không hợp lệ',
      );

      return decoded.cast<String>();
    }

    throw _httpError('Lấy providers thất bại', res);
  }
}
