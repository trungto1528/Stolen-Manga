class AnimePartDTO {
  final String name;
  final String url;
  final bool active;

  AnimePartDTO({
    required this.name,
    required this.url,
    required this.active,
  });

  factory AnimePartDTO.fromJson(Map<String, dynamic> json) {
    return AnimePartDTO(
      name: json['name'] ?? '',
      url: json['url'] ?? '',
      active: json['active'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'active': active,
    };
  }
}