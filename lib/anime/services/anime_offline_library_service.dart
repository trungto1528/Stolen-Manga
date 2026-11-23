
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/anime.dart';

class AnimeOfflineLibraryService {
  AnimeOfflineLibraryService._();

  static final AnimeOfflineLibraryService instance =
  AnimeOfflineLibraryService._();

  String _createAnimeKey(String animeTitle, String animeUrl) {
    var hash = 0x811c9dc5;

    for (final byte in utf8.encode(animeUrl)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }

    final title = animeTitle
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');

    final safeTitle = title.isEmpty ? 'anime' : title;
    final shortTitle =
    safeTitle.length > 32 ? safeTitle.substring(0, 32) : safeTitle;

    return '${shortTitle}_$hash';
  }

  Future<Directory> _getOfflineRoot() async {
    final root = await getApplicationSupportDirectory();

    return Directory(
      '${root.path}${Platform.pathSeparator}offline_anime',
    );
  }

  String _getDirectoryName(Directory directory) {
    final normalizedPath = directory.path.replaceAll(
      RegExp(r'[/\\]+$'),
      '',
    );

    final separatorIndex = normalizedPath.lastIndexOf(
      Platform.pathSeparator,
    );

    if (separatorIndex < 0) {
      return normalizedPath;
    }

    return normalizedPath.substring(separatorIndex + 1);
  }

  Future<List<AnimeSearchResult>> getDownloadedAnime() async {
    final results = <AnimeSearchResult>[];

    try {
      final root = await _getOfflineRoot();

      if (!await root.exists()) {
        debugPrint('[OFFLINE LIBRARY] Directory does not exist: ${root.path}');
        return results;
      }

      debugPrint('[OFFLINE LIBRARY] Scanning: ${root.path}');

      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;

        try {
          final metadataFile = File(
            '${entity.path}${Platform.pathSeparator}metadata.json',
          );

          if (!await metadataFile.exists()) {
            debugPrint(
              '[OFFLINE LIBRARY] Missing metadata: ${entity.path}',
            );
            continue;
          }

          final metadata = jsonDecode(
            await metadataFile.readAsString(),
          );

          if (metadata is! Map) continue;

          final animeTitle = metadata['animeTitle']?.toString() ?? '';
          final animeUrl = metadata['animeUrl']?.toString() ?? '';

          if (animeTitle.isEmpty || animeUrl.isEmpty) {
            debugPrint(
              '[OFFLINE LIBRARY] Invalid metadata: ${entity.path}',
            );
            continue;
          }

          final expectedKey = _createAnimeKey(animeTitle, animeUrl);
          final actualKey = _getDirectoryName(entity);

          if (actualKey != expectedKey) {
            debugPrint(
              '[OFFLINE LIBRARY] Anime key mismatch: '
                  '$actualKey != $expectedKey',
            );
            continue;
          }

          final firstDownloadedEpisodeUrl =
          await _getFirstDownloadedEpisodeUrl(entity);

          if (firstDownloadedEpisodeUrl == null) {
            debugPrint(
              '[OFFLINE LIBRARY] No completed episode: ${entity.path}',
            );
            continue;
          }

          results.add(
            AnimeSearchResult(
              name: animeTitle,
              url: animeUrl,
              poster: metadata['coverUrl']?.toString() ?? '',
              epUrl: firstDownloadedEpisodeUrl,
              label: 'Đã tải',
              score: '',
            ),
          );

          debugPrint('[OFFLINE LIBRARY] Found: $animeTitle');
        } catch (e, stackTrace) {
          debugPrint('[OFFLINE LIBRARY] Skip invalid anime: $e');
          debugPrint('$stackTrace');
        }
      }

      results.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

      debugPrint(
        '[OFFLINE LIBRARY] Found ${results.length} downloaded anime',
      );
    } catch (e, stackTrace) {
      debugPrint('[OFFLINE LIBRARY ERROR] $e');
      debugPrint('$stackTrace');
    }

    return results;
  }

  Future<String?> _getFirstDownloadedEpisodeUrl(
      Directory animeDirectory,
      ) async {
    await for (final entity in animeDirectory.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final markerFile = File(
        '${entity.path}${Platform.pathSeparator}complete.json',
      );

      final videoFile = File(
        '${entity.path}${Platform.pathSeparator}video.mp4',
      );

      if (!await markerFile.exists() || !await videoFile.exists()) {
        continue;
      }

      try {
        final marker = jsonDecode(await markerFile.readAsString());

        if (marker is! Map || marker['completed'] != true) {
          continue;
        }

        if (await videoFile.length() == 0) {
          continue;
        }

        final episodeUrl = marker['episodeUrl']?.toString() ?? '';

        if (episodeUrl.isNotEmpty) {
          return episodeUrl;
        }
      } catch (e) {
        debugPrint('[OFFLINE LIBRARY] Invalid episode marker: $e');
      }
    }

    return null;
  }
}
