class AnimeSearchResult {
  final String name;
  final String url;
  final String poster;
  final String epUrl;
  final String label;
  final String score;

  AnimeSearchResult({
    required this.name,
    required this.url,
    required this.poster,
    required this.epUrl,
    required this.label,
    required this.score,
  });

  factory AnimeSearchResult.fromJson(Map<String, dynamic> json) {
    return AnimeSearchResult(
      name: json['name'] ?? '',
      url: json['url'] ?? '',
      poster: json['poster'] ?? '',
      epUrl: json['ep_url'] ?? '',
      label: json['label'] ?? '',
      score: json['score'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'poster': poster,
      'ep_url': epUrl,
      'label': label,
      'score': score,
    };
  }
}

class AnimeEpisode {
  final int number;
  final String title;
  final String url;
  final String episodeId;

  AnimeEpisode({
    required this.number,
    required this.title,
    required this.url,
    required this.episodeId,
  });

  factory AnimeEpisode.fromJson(Map<String, dynamic> json) {
    return AnimeEpisode(
      number: json['number'] ?? 0,
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      episodeId: json['episodeId'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'number': number,
      'title': title,
      'url': url,
      'episodeId': episodeId,
    };
  }
}

class AnimeDetail {
  final String title;
  final String cover;
  final String description;
  final String status;
  final String year;
  final String type;
  final List<String> genres;
  final List<String> studios;
  final List<AnimeEpisode> episodes;

  AnimeDetail({
    required this.title,
    required this.cover,
    required this.description,
    required this.status,
    required this.year,
    required this.type,
    required this.genres,
    required this.studios,
    required this.episodes,
  });

  factory AnimeDetail.fromJson(Map<String, dynamic> json) {
    return AnimeDetail(
      title: json['title'] ?? '',
      cover: json['cover'] ?? '',
      description: json['description'] ?? '',
      status: json['status'] ?? '',
      year: json['year'] ?? '',
      type: json['type'] ?? '',
      genres: (json['genres'] as List<dynamic>? ?? []).cast<String>(),
      studios: (json['studios'] as List<dynamic>? ?? []).cast<String>(),
      episodes: (json['episodes'] as List<dynamic>? ?? [])
          .map((e) => AnimeEpisode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class AnimeStream {
  final String hlsUrl;
  final String serverName;
  final Map<String, String> headers;

  AnimeStream({
    required this.hlsUrl,
    required this.serverName,
    required this.headers,
  });

  factory AnimeStream.fromJson(Map<String, dynamic> json) {
    return AnimeStream(
      hlsUrl: json['hlsUrl'] ?? '',
      serverName: json['serverName'] ?? '',
      headers: Map<String, String>.from(json['headers'] ?? {}),
    );
  }
}

class CategoryDTO {
  final int id;
  final String name;
  final String slug;

  CategoryDTO({
    required this.id,
    required this.name,
    required this.slug,
  });

  factory CategoryDTO.fromJson(Map<String, dynamic> json) {
    return CategoryDTO(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      slug: json['slug'] ?? '',
    );
  }
}

class YearDTO {
  final int value;
  final String label;

  YearDTO({
    required this.value,
    required this.label,
  });

  factory YearDTO.fromJson(Map<String, dynamic> json) {
    return YearDTO(
      value: json['value'] ?? 0,
      label: json['label'] ?? '',
    );
  }
}

class StatusDTO {
  final String value;
  final String label;

  StatusDTO({
    required this.value,
    required this.label,
  });

  factory StatusDTO.fromJson(Map<String, dynamic> json) {
    return StatusDTO(
      value: json['value'] ?? '',
      label: json['label'] ?? '',
    );
  }
}

class SortDTO {
  final String value;
  final String label;

  SortDTO({
    required this.value,
    required this.label,
  });

  factory SortDTO.fromJson(Map<String, dynamic> json) {
    return SortDTO(
      value: json['value'] ?? '',
      label: json['label'] ?? '',
    );
  }
}

class AnimeFilterMetadata {
  final List<CategoryDTO> categories;
  final List<YearDTO> years;
  final List<StatusDTO> statuses;
  final List<SortDTO> sorts;

  AnimeFilterMetadata({
    required this.categories,
    required this.years,
    required this.statuses,
    required this.sorts,
  });

  factory AnimeFilterMetadata.fromJson(Map<String, dynamic> json) {
    return AnimeFilterMetadata(
      categories: (json['categories'] as List<dynamic>? ?? [])
          .map((e) => CategoryDTO.fromJson(e as Map<String, dynamic>))
          .toList(),
      years: (json['years'] as List<dynamic>? ?? [])
          .map((e) => YearDTO.fromJson(e as Map<String, dynamic>))
          .toList(),
      statuses: (json['statuses'] as List<dynamic>? ?? [])
          .map((e) => StatusDTO.fromJson(e as Map<String, dynamic>))
          .toList(),
      sorts: (json['sorts'] as List<dynamic>? ?? [])
          .map((e) => SortDTO.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
