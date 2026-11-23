import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/anime_service.dart';

final animeServiceProvider = Provider<AnimeService>((ref) {
  return AnimeService();
});