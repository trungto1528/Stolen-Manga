
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/anime.dart';
import 'anime_service.dart';

class AnimeDownloadProgress {
  final String status;
  final int completed;
  final int total;
  final bool isDownloading;
  final bool isPaused;
  final bool isCancelled;
  final bool isCompleted;
  final String? error;

  const AnimeDownloadProgress({
    this.status = '',
    this.completed = 0,
    this.total = 0,
    this.isDownloading = false,
    this.isPaused = false,
    this.isCancelled = false,
    this.isCompleted = false,
    this.error,
  });

  double get progress {
    if (total <= 0) return 0;
    return (completed / total).clamp(0.0, 1.0);
  }

  int get percent => (progress * 100).round();
}

class _HlsSegment {
  final int index;
  final Uri uri;

  const _HlsSegment({required this.index, required this.uri});
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

class AnimeDownloadService {
  AnimeDownloadService._();

  static final AnimeDownloadService instance = AnimeDownloadService._();

  static const int _maxConcurrentSegments = 6;
  static const int _maxAttempts = 4;
  static const Duration _requestTimeout = Duration(seconds: 60);

  final Map<String, Future<void>> _activeDownloads = {};
  final Map<String, ValueNotifier<AnimeDownloadProgress>> _progressNotifiers =
  {};

  final Set<String> _pauseRequested = {};
  final Set<String> _cancelRequested = {};
  final Map<String, Completer<void>> _resumeCompleters = {};

  ValueNotifier<AnimeDownloadProgress> progressFor(String downloadId) {
    return _progressNotifiers.putIfAbsent(
      downloadId,
          () => ValueNotifier(const AnimeDownloadProgress()),
    );
  }

  bool isDownloading(String downloadId) {
    return _activeDownloads.containsKey(downloadId);
  }

  bool isPaused(String downloadId) {
    return _pauseRequested.contains(downloadId) &&
        _activeDownloads.containsKey(downloadId);
  }

  void _updateProgress(
      String downloadId, {
        String? status,
        int? completed,
        int? total,
        bool? isDownloading,
        bool? isPaused,
        bool? isCancelled,
        bool? isCompleted,
        String? error,
        bool clearError = false,
      }) {
    final notifier = progressFor(downloadId);
    final old = notifier.value;

    notifier.value = AnimeDownloadProgress(
      status: status ?? old.status,
      completed: completed ?? old.completed,
      total: total ?? old.total,
      isDownloading: isDownloading ?? old.isDownloading,
      isPaused: isPaused ?? old.isPaused,
      isCancelled: isCancelled ?? old.isCancelled,
      isCompleted: isCompleted ?? old.isCompleted,
      error: clearError ? null : (error ?? old.error),
    );
  }

  void pauseDownload(String downloadId) {
    if (!_activeDownloads.containsKey(downloadId)) return;
    if (_cancelRequested.contains(downloadId)) return;
    if (_pauseRequested.contains(downloadId)) return;

    _pauseRequested.add(downloadId);

    _updateProgress(
      downloadId,
      status: 'Đang tạm dừng...',
      isDownloading: false,
      isPaused: true,
    );
  }

  void resumeDownload(String downloadId) {
    if (!_activeDownloads.containsKey(downloadId)) return;
    if (!_pauseRequested.contains(downloadId)) return;
    if (_cancelRequested.contains(downloadId)) return;

    _pauseRequested.remove(downloadId);

    final completer = _resumeCompleters.remove(downloadId);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }

    _updateProgress(
      downloadId,
      status: 'Đang tiếp tục tải...',
      isDownloading: true,
      isPaused: false,
      clearError: true,
    );
  }

  void cancelDownload(String downloadId) {
    if (!_activeDownloads.containsKey(downloadId)) return;
    if (_cancelRequested.contains(downloadId)) return;

    _cancelRequested.add(downloadId);
    _pauseRequested.remove(downloadId);

    final completer = _resumeCompleters.remove(downloadId);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }

    _updateProgress(
      downloadId,
      status: 'Đang hủy và dọn dữ liệu...',
      isDownloading: false,
      isPaused: false,
      isCancelled: false,
    );
  }

  Future<void> _waitIfPaused(String downloadId) async {
    while (_pauseRequested.contains(downloadId)) {
      if (_cancelRequested.contains(downloadId)) {
        throw const _DownloadCancelled();
      }

      final completer = _resumeCompleters.putIfAbsent(
        downloadId,
        Completer<void>.new,
      );

      await completer.future;
    }

    if (_cancelRequested.contains(downloadId)) {
      throw const _DownloadCancelled();
    }
  }

  void _checkCancelled(String downloadId) {
    if (_cancelRequested.contains(downloadId)) {
      throw const _DownloadCancelled();
    }
  }

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

  String _createEpisodeKey(AnimeEpisode episode) {
    final number = episode.number.toString().padLeft(4, '0');
    return 'episode_$number';
  }

  String createDownloadId(
      String animeTitle,
      String animeUrl,
      AnimeEpisode episode,
      ) {
    return '${_createAnimeKey(animeTitle, animeUrl)}_${_createEpisodeKey(episode)}';
  }

  Future<Directory> _getAnimeDirectory(
      String animeTitle,
      String animeUrl,
      ) async {
    final root = await getApplicationSupportDirectory();
    final animeKey = _createAnimeKey(animeTitle, animeUrl);

    return Directory(
      '${root.path}${Platform.pathSeparator}'
          'offline_anime${Platform.pathSeparator}$animeKey',
    );
  }

  Future<Directory> _getEpisodeDirectory(
      String animeTitle,
      String animeUrl,
      AnimeEpisode episode,
      ) async {
    final animeDirectory = await _getAnimeDirectory(animeTitle, animeUrl);

    return Directory(
      '${animeDirectory.path}${Platform.pathSeparator}'
          '${_createEpisodeKey(episode)}',
    );
  }

  Future<void> _deleteEpisodeDirectory(Directory directory) async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  // ---------------------------------------------------------------------------
  // ANIME COVER
  // ---------------------------------------------------------------------------

  Future<File?> _downloadAnimeCover({
    required String animeTitle,
    required String animeUrl,
    String? coverUrl,
    Map<String, String>? headers,
  }) async {
    if (coverUrl == null || coverUrl.trim().isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(coverUrl.trim());

    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final animeDirectory = await _getAnimeDirectory(
      animeTitle,
      animeUrl,
    );

    await animeDirectory.create(recursive: true);

    final coverFile = File(
      '${animeDirectory.path}${Platform.pathSeparator}cover.jpg',
    );

    // Không tải lại nếu cover đã tồn tại và hợp lệ.
    if (await coverFile.exists()) {
      try {
        if (await coverFile.length() > 0) {
          return coverFile;
        }
      } catch (_) {
        // File không đọc được, thử tải lại.
      }
    }

    final temporaryFile = File(
      '${animeDirectory.path}${Platform.pathSeparator}cover.tmp',
    );

    final requestHeaders = <String, String>{
      'Referer': 'https://animehay17.site/',
      'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
      ...?headers,
    };

    final client = http.Client();

    try {
      final request = http.Request('GET', uri)
        ..headers.addAll(requestHeaders);

      final response = await client
          .send(request)
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        debugPrint(
          'Không thể tải cover anime: HTTP ${response.statusCode}',
        );
        return null;
      }

      final bytes = await response.stream.toBytes();

      if (bytes.isEmpty) {
        debugPrint('Cover anime tải về bị rỗng.');
        return null;
      }

      await temporaryFile.writeAsBytes(
        bytes,
        flush: true,
      );

      if (await coverFile.exists()) {
        await coverFile.delete();
      }

      await temporaryFile.rename(coverFile.path);

      debugPrint('Đã lưu cover anime: ${coverFile.path}');

      return coverFile;
    } catch (e) {
      debugPrint('Không thể tải cover anime "$animeTitle": $e');

      try {
        if (await temporaryFile.exists()) {
          await temporaryFile.delete();
        }
      } catch (_) {}

      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _saveAnimeMetadata({
    required String animeTitle,
    required String animeUrl,
    String? coverUrl,
  }) async {
    final animeDirectory = await _getAnimeDirectory(
      animeTitle,
      animeUrl,
    );

    await _writeJson(
      File(
        '${animeDirectory.path}${Platform.pathSeparator}metadata.json',
      ),
      {
        'animeTitle': animeTitle,
        'animeUrl': animeUrl,
        'coverUrl': coverUrl,
        'coverFile': 'cover.jpg',
        'updatedAt': DateTime.now().toIso8601String(),
      },
    );
  }

  // ---------------------------------------------------------------------------
  // DOWNLOADED EPISODE
  // ---------------------------------------------------------------------------

  Future<File?> getDownloadedEpisodeFile({
    required String animeTitle,
    required String animeUrl,
    required AnimeEpisode episode,
  }) async {
    final episodeDirectory = await _getEpisodeDirectory(
      animeTitle,
      animeUrl,
      episode,
    );

    final marker = File('${episodeDirectory.path}/complete.json');
    final video = File('${episodeDirectory.path}/video.mp4');

    if (!await marker.exists() || !await video.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await marker.readAsString());

      if (decoded is! Map || decoded['completed'] != true) {
        return null;
      }

      if (await video.length() == 0) return null;

      return video;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isEpisodeDownloaded({
    required String animeTitle,
    required String animeUrl,
    required AnimeEpisode episode,
  }) async {
    return await getDownloadedEpisodeFile(
      animeTitle: animeTitle,
      animeUrl: animeUrl,
      episode: episode,
    ) !=
        null;
  }

  // ---------------------------------------------------------------------------
  // DOWNLOAD EPISODE
  // ---------------------------------------------------------------------------

  Future<void> downloadEpisode({
    required String animeTitle,
    required String animeUrl,
    required AnimeEpisode episode,
    required AnimeService animeService,
    String? coverUrl,
  }) async {
    final downloadId = createDownloadId(animeTitle, animeUrl, episode);

    final activeTask = _activeDownloads[downloadId];
    if (activeTask != null) {
      await activeTask;
      return;
    }

    final task = _downloadEpisodeInternal(
      downloadId: downloadId,
      animeTitle: animeTitle,
      animeUrl: animeUrl,
      episode: episode,
      animeService: animeService,
      coverUrl: coverUrl,
    );

    _activeDownloads[downloadId] = task;

    try {
      await task;
    } finally {
      _activeDownloads.remove(downloadId);
      _pauseRequested.remove(downloadId);
      _cancelRequested.remove(downloadId);

      final completer = _resumeCompleters.remove(downloadId);
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _downloadEpisodeInternal({
    required String downloadId,
    required String animeTitle,
    required String animeUrl,
    required AnimeEpisode episode,
    required AnimeService animeService,
    String? coverUrl,
  }) async {
    final episodeDirectory = await _getEpisodeDirectory(
      animeTitle,
      animeUrl,
      episode,
    );

    final videoFile = File('${episodeDirectory.path}/video.mp4');
    final completeMarker = File('${episodeDirectory.path}/complete.json');

    try {
      // Tạo thư mục anime và tải cover ngay khi bắt đầu tải tập.
      // Lỗi tải cover không làm ảnh hưởng đến quá trình tải video.
      await _downloadAnimeCover(
        animeTitle: animeTitle,
        animeUrl: animeUrl,
        coverUrl: coverUrl,
      );

      _checkCancelled(downloadId);

      final existingVideo = await getDownloadedEpisodeFile(
        animeTitle: animeTitle,
        animeUrl: animeUrl,
        episode: episode,
      );

      if (existingVideo != null) {
        await _saveAnimeMetadata(
          animeTitle: animeTitle,
          animeUrl: animeUrl,
          coverUrl: coverUrl,
        );

        _updateProgress(
          downloadId,
          status: 'Đã tải hoàn tất',
          isDownloading: false,
          isPaused: false,
          isCancelled: false,
          isCompleted: true,
          clearError: true,
        );
        return;
      }

      await episodeDirectory.create(recursive: true);

      _updateProgress(
        downloadId,
        status: 'Đang lấy nguồn phát...',
        completed: 0,
        total: 0,
        isDownloading: true,
        isPaused: false,
        isCancelled: false,
        isCompleted: false,
        clearError: true,
      );

      _checkCancelled(downloadId);

      final stream = await animeService.getStream(episode.url);

      _checkCancelled(downloadId);

      if (stream.hlsUrl.isEmpty) {
        throw Exception('Không tìm thấy đường dẫn HLS của tập phim.');
      }

      final headers = <String, String>{
        'Referer': 'https://animehay17.site/',
        'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
        ...stream.headers,
      };

      final playlistUri = await _resolveMediaPlaylist(
        Uri.parse(stream.hlsUrl),
        headers,
      );

      _checkCancelled(downloadId);

      final segments = await _parseMediaPlaylist(playlistUri, headers);

      _checkCancelled(downloadId);

      if (segments.isEmpty) {
        throw Exception('Playlist không có segment video.');
      }

      final segmentsDirectory = Directory(
        '${episodeDirectory.path}${Platform.pathSeparator}segments',
      );

      await segmentsDirectory.create(recursive: true);

      final manifestFile = File('${episodeDirectory.path}/download.json');

      final fingerprint = segments
          .map((segment) => _stableSegmentUri(segment.uri))
          .join('\n');

      var shouldReuseSegments = false;

      if (await manifestFile.exists()) {
        try {
          final oldManifest = jsonDecode(await manifestFile.readAsString());

          shouldReuseSegments =
              oldManifest is Map &&
                  oldManifest['fingerprint'] == fingerprint;
        } catch (_) {
          shouldReuseSegments = false;
        }
      }

      if (!shouldReuseSegments) {
        if (await segmentsDirectory.exists()) {
          await segmentsDirectory.delete(recursive: true);
        }

        await segmentsDirectory.create(recursive: true);
      }

      await _writeJson(manifestFile, {
        'animeTitle': animeTitle,
        'animeUrl': animeUrl,
        'episodeNumber': episode.number,
        'episodeTitle': episode.title,
        'episodeUrl': episode.url,
        'playlistUrl': playlistUri.toString(),
        'fingerprint': fingerprint,
        'segmentCount': segments.length,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      _checkCancelled(downloadId);

      var completed = 0;

      for (final segment in segments) {
        final segmentFile = _segmentFile(
          segmentsDirectory,
          segment.index,
        );

        if (await segmentFile.exists() &&
            await segmentFile.length() > 0) {
          completed++;
        }
      }

      _updateProgress(
        downloadId,
        status: 'Đang tải segment...',
        completed: completed,
        total: segments.length,
        isDownloading: true,
        isPaused: false,
      );

      final client = http.Client();

      try {
        await _downloadSegments(
          downloadId: downloadId,
          client: client,
          headers: headers,
          segments: segments,
          segmentsDirectory: segmentsDirectory,
          initialCompleted: completed,
          onProgress: (value) {
            _updateProgress(
              downloadId,
              status: 'Đang tải segment...',
              completed: value,
              total: segments.length,
              isDownloading: true,
              isPaused: false,
            );
          },
        );
      } finally {
        client.close();
      }

      _checkCancelled(downloadId);

      _updateProgress(
        downloadId,
        status: 'Đang ghép video MP4...',
        completed: segments.length,
        total: segments.length,
        isDownloading: true,
        isPaused: false,
      );

      final concatFile = File('${episodeDirectory.path}/segments.txt');

      await _writeConcatFile(
        concatFile,
        segments,
        segmentsDirectory,
      );

      _checkCancelled(downloadId);

      final temporaryVideo = File(
        '${episodeDirectory.path}/video.part.mp4',
      );

      if (await temporaryVideo.exists()) {
        await temporaryVideo.delete();
      }

      final session = await FFmpegKit.executeWithArguments([
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        concatFile.path,
        '-map',
        '0:v:0',
        '-map',
        '0:a?',
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        temporaryVideo.path,
      ]);

      _checkCancelled(downloadId);

      final returnCode = await session.getReturnCode();
      final returnCodeValue = returnCode?.getValue();

      if (returnCodeValue != 0) {
        final output = await session.getOutput();

        throw Exception(
          'FFmpeg không thể ghép video. '
              '${output?.trim().isNotEmpty == true ? output : returnCode}',
        );
      }

      if (!await temporaryVideo.exists() ||
          await temporaryVideo.length() < 1024) {
        throw Exception('File MP4 sau khi ghép không hợp lệ.');
      }

      _checkCancelled(downloadId);

      if (await videoFile.exists()) {
        await videoFile.delete();
      }

      await temporaryVideo.rename(videoFile.path);

      _checkCancelled(downloadId);

      await _writeJson(completeMarker, {
        'completed': true,
        'animeTitle': animeTitle,
        'animeUrl': animeUrl,
        'coverUrl': coverUrl,
        'episodeNumber': episode.number,
        'episodeTitle': episode.title,
        'episodeId': episode.episodeId,
        'episodeUrl': episode.url,
        'videoFile': 'video.mp4',
        'fileSize': await videoFile.length(),
        'completedAt': DateTime.now().toIso8601String(),
      });

      _checkCancelled(downloadId);

      await _saveAnimeMetadata(
        animeTitle: animeTitle,
        animeUrl: animeUrl,
        coverUrl: coverUrl,
      );

      _checkCancelled(downloadId);

      // Chỉ xóa segment sau khi MP4 và complete.json đã được tạo thành công.
      if (await segmentsDirectory.exists()) {
        await segmentsDirectory.delete(recursive: true);
      }

      if (await concatFile.exists()) {
        await concatFile.delete();
      }

      if (await manifestFile.exists()) {
        await manifestFile.delete();
      }

      _checkCancelled(downloadId);

      _updateProgress(
        downloadId,
        status: 'Tải hoàn tất',
        completed: segments.length,
        total: segments.length,
        isDownloading: false,
        isPaused: false,
        isCancelled: false,
        isCompleted: true,
        clearError: true,
      );
    } on _DownloadCancelled {
      // Worker đã dừng trước khi đi đến đây.
      // Xóa toàn bộ dữ liệu tạm của riêng tập đang bị hủy.
      try {
        await _deleteEpisodeDirectory(episodeDirectory);
      } catch (e) {
        debugPrint('Không thể dọn dữ liệu tập đã hủy: $e');
      }

      _updateProgress(
        downloadId,
        status: 'Đã hủy tải và dọn dữ liệu',
        completed: 0,
        total: 0,
        isDownloading: false,
        isPaused: false,
        isCancelled: true,
        isCompleted: false,
        clearError: true,
      );
    } catch (e) {
      _updateProgress(
        downloadId,
        status: 'Tải thất bại',
        isDownloading: false,
        isPaused: false,
        isCompleted: false,
        error: e.toString(),
      );

      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // DOWNLOAD SEGMENTS
  // ---------------------------------------------------------------------------

  Future<void> _downloadSegments({
    required String downloadId,
    required http.Client client,
    required Map<String, String> headers,
    required List<_HlsSegment> segments,
    required Directory segmentsDirectory,
    required int initialCompleted,
    required ValueChanged<int> onProgress,
  }) async {
    var nextIndex = 0;
    var completed = initialCompleted;
    Object? firstError;

    final workerCount = segments.length < _maxConcurrentSegments
        ? segments.length
        : _maxConcurrentSegments;

    Future<void> worker() async {
      while (true) {
        await _waitIfPaused(downloadId);

        if (_cancelRequested.contains(downloadId)) return;

        final currentIndex = nextIndex++;
        if (currentIndex >= segments.length) return;

        final segment = segments[currentIndex];

        final destination = _segmentFile(
          segmentsDirectory,
          segment.index,
        );

        if (await destination.exists() &&
            await destination.length() > 0) {
          continue;
        }

        try {
          await _downloadSegment(
            downloadId: downloadId,
            client: client,
            headers: headers,
            segment: segment,
            destination: destination,
          );

          completed++;
          onProgress(completed);
        } on _DownloadCancelled {
          return;
        } catch (e) {
          firstError ??= e;
          _cancelRequested.add(downloadId);
          return;
        }
      }
    }

    await Future.wait(
      List.generate(workerCount, (_) => worker()),
    );

    if (firstError != null) {
      throw Exception('Không thể tải segment: $firstError');
    }

    if (_cancelRequested.contains(downloadId)) {
      throw const _DownloadCancelled();
    }
  }

  Future<void> _downloadSegment({
    required String downloadId,
    required http.Client client,
    required Map<String, String> headers,
    required _HlsSegment segment,
    required File destination,
  }) async {
    final temporaryFile = File('${destination.path}.part');
    Object? lastError;

    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      if (_cancelRequested.contains(downloadId)) {
        throw const _DownloadCancelled();
      }

      await _waitIfPaused(downloadId);

      try {
        if (await temporaryFile.exists()) {
          await temporaryFile.delete();
        }

        final request = http.Request('GET', segment.uri)
          ..headers.addAll(headers);

        final response = await client
            .send(request)
            .timeout(_requestTimeout);

        if (response.statusCode != 200) {
          throw HttpException(
            'HTTP ${response.statusCode} khi tải segment ${segment.index}',
          );
        }

        final sink = temporaryFile.openWrite();

        try {
          await for (final chunk in response.stream) {
            if (_cancelRequested.contains(downloadId)) {
              throw const _DownloadCancelled();
            }

            sink.add(chunk);
          }

          await sink.flush();
        } finally {
          await sink.close();
        }

        if (!await temporaryFile.exists() ||
            await temporaryFile.length() == 0) {
          throw Exception('Segment tải về rỗng.');
        }

        if (_cancelRequested.contains(downloadId)) {
          throw const _DownloadCancelled();
        }

        if (await destination.exists()) {
          await destination.delete();
        }

        await temporaryFile.rename(destination.path);
        return;
      } on _DownloadCancelled {
        rethrow;
      } catch (e) {
        lastError = e;

        if (await temporaryFile.exists()) {
          await temporaryFile.delete();
        }

        if (attempt < _maxAttempts) {
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }
    }

    throw Exception(
      'Đã thử tải segment $_maxAttempts lần nhưng thất bại: $lastError',
    );
  }

  // ---------------------------------------------------------------------------
  // HLS
  // ---------------------------------------------------------------------------

  Future<Uri> _resolveMediaPlaylist(
      Uri playlistUri,
      Map<String, String> headers, {
        int depth = 0,
      }) async {
    if (depth > 3) {
      throw Exception('Playlist HLS lồng nhau quá nhiều cấp.');
    }

    final response = await http
        .get(playlistUri, headers: headers)
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw HttpException(
        'Không thể tải playlist HLS: HTTP ${response.statusCode}',
      );
    }

    final content = utf8.decode(
      response.bodyBytes,
      allowMalformed: true,
    );

    if (!content.trimLeft().startsWith('#EXTM3U')) {
      throw Exception('Nội dung trả về không phải playlist HLS.');
    }

    final lines = content
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .toList();

    Uri? selectedVariant;
    var highestBandwidth = -1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;

      final bandwidthMatch = RegExp(
        r'BANDWIDTH=(\d+)',
      ).firstMatch(line);

      final bandwidth =
          int.tryParse(bandwidthMatch?.group(1) ?? '') ?? 0;

      for (var j = i + 1; j < lines.length; j++) {
        if (lines[j].isEmpty || lines[j].startsWith('#')) {
          continue;
        }

        if (bandwidth > highestBandwidth) {
          highestBandwidth = bandwidth;
          selectedVariant = playlistUri.resolve(lines[j]);
        }

        break;
      }
    }

    if (selectedVariant != null) {
      return _resolveMediaPlaylist(
        selectedVariant,
        headers,
        depth: depth + 1,
      );
    }

    return playlistUri;
  }

  Future<List<_HlsSegment>> _parseMediaPlaylist(
      Uri playlistUri,
      Map<String, String> headers,
      ) async {
    final response = await http
        .get(playlistUri, headers: headers)
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw HttpException(
        'Không thể tải media playlist: HTTP ${response.statusCode}',
      );
    }

    final content = utf8.decode(
      response.bodyBytes,
      allowMalformed: true,
    );

    final lines = content
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .toList();

    final segments = <_HlsSegment>[];

    for (final line in lines) {
      if (line.isEmpty || line.startsWith('#')) continue;

      segments.add(
        _HlsSegment(
          index: segments.length,
          uri: playlistUri.resolve(line),
        ),
      );
    }

    return segments;
  }

  String _stableSegmentUri(Uri uri) {
    return uri.replace(query: null, fragment: null).toString();
  }

  // ---------------------------------------------------------------------------
  // FILE HELPERS
  // ---------------------------------------------------------------------------

  File _segmentFile(Directory directory, int index) {
    final name = 'segment_${index.toString().padLeft(5, '0')}.ts';

    return File(
      '${directory.path}${Platform.pathSeparator}$name',
    );
  }

  Future<void> _writeConcatFile(
      File concatFile,
      List<_HlsSegment> segments,
      Directory segmentsDirectory,
      ) async {
    final buffer = StringBuffer();

    for (final segment in segments) {
      final file = _segmentFile(
        segmentsDirectory,
        segment.index,
      );

      if (!await file.exists() || await file.length() == 0) {
        throw Exception('Thiếu segment ${segment.index}.');
      }

      final escapedPath = file.path
          .replaceAll(r'\', r'\\')
          .replaceAll("'", r"\'");

      buffer.writeln("file '$escapedPath'");
    }

    await concatFile.writeAsString(
      buffer.toString(),
      flush: true,
    );
  }

  Future<void> _writeJson(
      File file,
      Map<String, dynamic> data,
      ) async {
    await file.parent.create(recursive: true);

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }
}
