
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
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

class _OrderedPipeWriter {
  final IOSink _sink;
  final String _downloadId;
  final Future<void> Function(String) _waitIfPaused;
  final void Function(String) _checkCancelled;

  int _nextIndex = 0;
  final Map<int, File> _buffer = {};
  Future<void> _writeChain = Future<void>.value();

  _OrderedPipeWriter({
    required IOSink sink,
    required String downloadId,
    required Future<void> Function(String) waitIfPaused,
    required void Function(String) checkCancelled,
  })  : _sink = sink,
        _downloadId = downloadId,
        _waitIfPaused = waitIfPaused,
        _checkCancelled = checkCancelled;

  Future<void> add(File file, int index) {
    if (index < _nextIndex || _buffer.containsKey(index)) {
      return Future.error(
        StateError('Segment $index đã được đưa vào pipe.'),
      );
    }

    _buffer[index] = file;
    _writeChain = _writeChain.then((_) => _flushReady());

    return _writeChain;
  }

  Future<void> _flushReady() async {
    while (true) {
      _checkCancelled(_downloadId);

      final file = _buffer.remove(_nextIndex);

      if (file == null) return;

      await for (final chunk in file.openRead()) {
        await _waitIfPaused(_downloadId);
        _checkCancelled(_downloadId);
        _sink.add(chunk);
      }

      await _sink.flush();
      _nextIndex++;
    }
  }

  Future<void> finish(int totalSegments) async {
    await _writeChain;
    _checkCancelled(_downloadId);

    if (_buffer.isNotEmpty || _nextIndex != totalSegments) {
      throw Exception(
        'Dữ liệu segment chưa liên tục: '
            'đã ghi $_nextIndex/$totalSegments segment.',
      );
    }
  }
}

class AnimeDownloadService {
  AnimeDownloadService._();

  static final AnimeDownloadService instance = AnimeDownloadService._();

  static const int _maxConcurrentSegments = 12;
  static const int _maxAttempts = 4;
  static const Duration _requestTimeout = Duration(seconds: 60);
  static const Duration _ffmpegCancelTimeout = Duration(seconds: 5);
  static const Duration _ffmpegCallbackTimeout = Duration(seconds: 15);
  static const Duration _ffmpegFinishTimeout = Duration(minutes: 3);

  final Map<String, Future<void>> _activeDownloads = {};

  final Map<String, ValueNotifier<AnimeDownloadProgress>>
  _progressNotifiers = {};

  final Set<String> _pauseRequested = {};
  final Set<String> _cancelRequested = {};
  final Set<String> _preserveEpisodeDirectory = {};

  final Map<String, Completer<void>> _resumeCompleters = {};
  final Map<String, Completer<void>> _cancelCompleters = {};

  final Map<String, int> _ffmpegSessionIds = {};

  final Map<String, Set<http.Client>> _activeHttpClients = {};

  final Map<String, Future<File?>> _coverDownloadTasks = {};

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

    // Đánh thức tác vụ đang chờ resume.
    final resumeCompleter = _resumeCompleters.remove(downloadId);

    if (resumeCompleter != null && !resumeCompleter.isCompleted) {
      resumeCompleter.complete();
    }

    // Đánh thức tác vụ đang chờ FFmpeg hoàn tất.
    final cancelCompleter = _cancelCompleters[downloadId];

    if (cancelCompleter != null && !cancelCompleter.isCompleted) {
      cancelCompleter.complete();
    }

    // Đóng tất cả HTTP client đang tải segment.
    final clients = _activeHttpClients[downloadId];

    if (clients != null) {
      for (final client in clients.toList()) {
        try {
          client.close();
        } catch (e) {
          debugPrint('Không thể đóng HTTP client: $e');
        }
      }
    }

    // Gửi lệnh dừng FFmpeg ngay lập tức.
    final sessionId = _ffmpegSessionIds[downloadId];

    if (sessionId != null) {
      unawaited(
        FFmpegKit.cancel(sessionId).catchError((Object error) {
          debugPrint('Không thể gửi lệnh hủy FFmpeg: $error');
        }),
      );
    }

    // Giữ isDownloading theo trạng thái tác vụ thực tế.
    // UI vẫn khóa chọn tập cho đến khi tác vụ cũ kết thúc.
    _updateProgress(
      downloadId,
      status: 'Đang hủy và dọn dữ liệu...',
      isDownloading: true,
      isPaused: false,
      isCancelled: false,
      isCompleted: false,
      clearError: true,
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

    _checkCancelled(downloadId);
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
    return '${_createAnimeKey(animeTitle, animeUrl)}_'
        '${_createEpisodeKey(episode)}';
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
    final animeDirectory = await _getAnimeDirectory(
      animeTitle,
      animeUrl,
    );

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
  // HTTP CLIENT MANAGEMENT
  // ---------------------------------------------------------------------------

  void _registerHttpClient(String downloadId, http.Client client) {
    _activeHttpClients.putIfAbsent(
      downloadId,
          () => <http.Client>{},
    ).add(client);
  }

  void _unregisterHttpClient(String downloadId, http.Client client) {
    final clients = _activeHttpClients[downloadId];

    if (clients == null) return;

    clients.remove(client);

    if (clients.isEmpty) {
      _activeHttpClients.remove(downloadId);
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

    final animeKey = _createAnimeKey(animeTitle, animeUrl);
    final activeTask = _coverDownloadTasks[animeKey];

    if (activeTask != null) {
      return activeTask;
    }

    final task = _downloadAnimeCoverInternal(
      animeTitle: animeTitle,
      animeUrl: animeUrl,
      uri: uri,
      headers: headers,
    );

    _coverDownloadTasks[animeKey] = task;

    try {
      return await task;
    } finally {
      if (identical(_coverDownloadTasks[animeKey], task)) {
        _coverDownloadTasks.remove(animeKey);
      }
    }
  }

  Future<File?> _downloadAnimeCoverInternal({
    required String animeTitle,
    required String animeUrl,
    required Uri uri,
    Map<String, String>? headers,
  }) async {
    final animeDirectory = await _getAnimeDirectory(
      animeTitle,
      animeUrl,
    );

    await animeDirectory.create(recursive: true);

    final coverFile = File(
      '${animeDirectory.path}${Platform.pathSeparator}cover.jpg',
    );

    if (await coverFile.exists()) {
      try {
        if (await coverFile.length() > 0) {
          return coverFile;
        }
      } catch (_) {}
    }

    final temporaryFile = File(
      '${animeDirectory.path}${Platform.pathSeparator}'
          'cover_${DateTime.now().microsecondsSinceEpoch}.tmp',
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

      await temporaryFile.writeAsBytes(bytes, flush: true);

      if (await coverFile.exists()) {
        try {
          if (await coverFile.length() > 0) {
            await temporaryFile.delete();
            return coverFile;
          }
        } catch (_) {}
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
    final downloadId = createDownloadId(
      animeTitle,
      animeUrl,
      episode,
    );

    final activeTask = _activeDownloads[downloadId];

    if (activeTask != null) {
      await activeTask;
      return;
    }

    _cancelCompleters[downloadId] = Completer<void>();

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
      _ffmpegSessionIds.remove(downloadId);
      _preserveEpisodeDirectory.remove(downloadId);

      final clients = _activeHttpClients.remove(downloadId);

      if (clients != null) {
        for (final client in clients) {
          try {
            client.close();
          } catch (_) {}
        }
      }

      final resumeCompleter = _resumeCompleters.remove(downloadId);

      if (resumeCompleter != null && !resumeCompleter.isCompleted) {
        resumeCompleter.complete();
      }

      final cancelCompleter = _cancelCompleters.remove(downloadId);

      if (cancelCompleter != null && !cancelCompleter.isCompleted) {
        cancelCompleter.complete();
      }

      final currentProgress = progressFor(downloadId).value;

      _updateProgress(
        downloadId,
        isDownloading: false,
        isPaused: false,
        status: currentProgress.isCancelled
            ? currentProgress.status
            : null,
      );
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
      _checkCancelled(downloadId);

      await _saveAnimeMetadata(
        animeTitle: animeTitle,
        animeUrl: animeUrl,
        coverUrl: coverUrl,
      );

      _checkCancelled(downloadId);

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

      final segments = await _parseMediaPlaylist(
        playlistUri,
        headers,
      );

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
          final oldManifest = jsonDecode(
            await manifestFile.readAsString(),
          );

          shouldReuseSegments = oldManifest is Map &&
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
        status: 'Đang tải và ghép segment...',
        completed: completed,
        total: segments.length,
        isDownloading: true,
        isPaused: false,
      );

      final client = http.Client();
      _registerHttpClient(downloadId, client);

      try {
        await _downloadAndMergeStreaming(
          downloadId: downloadId,
          client: client,
          headers: headers,
          segments: segments,
          segmentsDirectory: segmentsDirectory,
          videoFile: videoFile,
          initialCompleted: completed,
          onProgress: (value) {
            if (_cancelRequested.contains(downloadId)) return;

            _updateProgress(
              downloadId,
              status: 'Đang tải và ghép segment...',
              completed: value,
              total: segments.length,
              isDownloading: true,
              isPaused: false,
            );
          },
        );
      } finally {
        client.close();
        _unregisterHttpClient(downloadId, client);
      }

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

      if (await segmentsDirectory.exists()) {
        await segmentsDirectory.delete(recursive: true);
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
      final preserveDirectory =
      _preserveEpisodeDirectory.contains(downloadId);

      if (!preserveDirectory) {
        try {
          await _deleteEpisodeDirectory(episodeDirectory);
        } catch (e) {
          debugPrint('Không thể dọn dữ liệu tập đã hủy: $e');
        }
      } else {
        debugPrint(
          'Giữ lại thư mục tập phim vì chưa xác nhận FFmpeg đã kết thúc.',
        );
      }

      _updateProgress(
        downloadId,
        status: preserveDirectory
            ? 'Đã hủy, giữ dữ liệu tạm để bảo đảm an toàn'
            : 'Đã hủy tải và dọn dữ liệu',
        completed: 0,
        total: 0,
        isDownloading: false,
        isPaused: false,
        isCancelled: true,
        isCompleted: false,
        clearError: true,
      );
    } catch (e) {
      if (_cancelRequested.contains(downloadId)) {
        final preserveDirectory =
        _preserveEpisodeDirectory.contains(downloadId);

        if (!preserveDirectory) {
          try {
            await _deleteEpisodeDirectory(episodeDirectory);
          } catch (cleanupError) {
            debugPrint(
              'Không thể dọn dữ liệu tập đã hủy: $cleanupError',
            );
          }
        }

        _updateProgress(
          downloadId,
          status: preserveDirectory
              ? 'Đã hủy, giữ dữ liệu tạm để bảo đảm an toàn'
              : 'Đã hủy tải và dọn dữ liệu',
          completed: 0,
          total: 0,
          isDownloading: false,
          isPaused: false,
          isCancelled: true,
          isCompleted: false,
          clearError: true,
        );

        return;
      }

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
  // DOWNLOAD SEGMENT
  // ---------------------------------------------------------------------------

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
      _checkCancelled(downloadId);
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
            await _waitIfPaused(downloadId);
            _checkCancelled(downloadId);
            sink.add(chunk);
          }

          await sink.flush();
        } finally {
          await sink.close();
        }

        _checkCancelled(downloadId);

        if (!await temporaryFile.exists() ||
            await temporaryFile.length() == 0) {
          throw Exception('Segment tải về rỗng.');
        }

        if (await destination.exists()) {
          await destination.delete();
        }

        await temporaryFile.rename(destination.path);
        return;
      } on _DownloadCancelled {
        rethrow;
      } catch (e) {
        // Client bị đóng do yêu cầu hủy thì không được retry.
        _checkCancelled(downloadId);

        lastError = e;

        if (await temporaryFile.exists()) {
          await temporaryFile.delete();
        }

        if (attempt < _maxAttempts) {
          await Future.delayed(Duration(seconds: attempt * 2));
          _checkCancelled(downloadId);
        }
      }
    }

    throw Exception(
      'Đã thử tải segment $_maxAttempts lần nhưng thất bại: $lastError',
    );
  }

  // ---------------------------------------------------------------------------
  // FFMPEG CLEANUP
  // ---------------------------------------------------------------------------

  Future<void> _cancelFfmpegSession({
    required String downloadId,
    required int? sessionId,
    required Completer<dynamic> ffmpegCompleted,
    required Future<void> Function() closePipeWriter,
    required Future<void> Function() releasePipe,
  }) async {
    var callbackReceived = ffmpegCompleted.isCompleted;

    if (sessionId != null && !callbackReceived) {
      try {
        await FFmpegKit.cancel(sessionId).timeout(
          _ffmpegCancelTimeout,
        );
      } on TimeoutException {
        debugPrint('FFmpeg cancel request timeout: $downloadId');
      } catch (e) {
        debugPrint('FFmpeg cancel error: $e');
      }
    }

    await closePipeWriter();

    if (!callbackReceived && sessionId != null) {
      try {
        await ffmpegCompleted.future.timeout(
          _ffmpegCallbackTimeout,
        );

        callbackReceived = true;
      } on TimeoutException {
        callbackReceived = false;
      } catch (e) {
        debugPrint('FFmpeg callback error: $e');
      }
    }

    await releasePipe();

    if (!callbackReceived && sessionId != null) {
      _preserveEpisodeDirectory.add(downloadId);

      debugPrint(
        'Không xác nhận được FFmpeg đã dừng. '
            'Giữ lại file tạm: $downloadId',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // DOWNLOAD + MERGE STREAMING
  // ---------------------------------------------------------------------------

  Future<void> _downloadAndMergeStreaming({
    required String downloadId,
    required http.Client client,
    required Map<String, String> headers,
    required List<_HlsSegment> segments,
    required Directory segmentsDirectory,
    required File videoFile,
    required int initialCompleted,
    required ValueChanged<int> onProgress,
  }) async {
    final temporaryVideo = File('${videoFile.path}.part');

    if (await temporaryVideo.exists()) {
      await temporaryVideo.delete();
    }

    String? pipePath;
    IOSink? pipeSink;

    var pipeWriterClosed = false;
    var pipeReleased = false;
    var completed = initialCompleted;
    var nextIndex = 0;
    var firstErrorRecorded = false;
    Object? firstError;
    var stopWorkers = false;
    var ffmpegFinishedNormally = false;

    final workerCount = segments.length < _maxConcurrentSegments
        ? segments.length
        : _maxConcurrentSegments;

    dynamic ffmpegSession;
    final ffmpegCompleted = Completer<dynamic>();

    Future<void> closePipeWriter() async {
      if (pipeWriterClosed) return;

      pipeWriterClosed = true;

      try {
        await pipeSink?.flush();
      } catch (_) {}

      try {
        await pipeSink?.close();
      } catch (e) {
        debugPrint('Không thể đóng FFmpeg pipe writer: $e');
      }
    }

    Future<void> releasePipe() async {
      await closePipeWriter();

      if (pipeReleased || pipePath == null) return;

      pipeReleased = true;

      try {
        await FFmpegKitConfig.closeFFmpegPipe(pipePath);
      } catch (e) {
        debugPrint('Không thể giải phóng FFmpeg pipe: $e');
      }
    }

    Future<void> stopFfmpeg() async {
      final sessionId = _ffmpegSessionIds[downloadId];

      await _cancelFfmpegSession(
        downloadId: downloadId,
        sessionId: sessionId,
        ffmpegCompleted: ffmpegCompleted,
        closePipeWriter: closePipeWriter,
        releasePipe: releasePipe,
      );
    }

    try {
      _checkCancelled(downloadId);

      pipePath = await FFmpegKitConfig.registerNewFFmpegPipe();

      if (pipePath == null || pipePath.isEmpty) {
        throw Exception('Không thể tạo named pipe cho FFmpeg.');
      }

      _checkCancelled(downloadId);

      final ffmpegLaunch = FFmpegKit.executeWithArgumentsAsync(
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-fflags',
          '+genpts',
          '-f',
          'mpegts',
          '-i',
          pipePath,
          '-map',
          '0:v:0',
          '-map',
          '0:a?',
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          temporaryVideo.path,
        ],
            (session) {
          if (!ffmpegCompleted.isCompleted) {
            ffmpegCompleted.complete(session);
          }
        },
      );

      ffmpegSession = await ffmpegLaunch;

      final sessionId = ffmpegSession.getSessionId();

      if (sessionId is int) {
        _ffmpegSessionIds[downloadId] = sessionId;
      }

      // Nếu người dùng hủy trong lúc FFmpeg đang khởi tạo,
      // gửi lệnh hủy ngay sau khi lấy được session ID.
      if (_cancelRequested.contains(downloadId)) {
        if (sessionId is int) {
          try {
            await FFmpegKit.cancel(sessionId);
          } catch (e) {
            debugPrint('Không thể hủy FFmpeg vừa khởi tạo: $e');
          }
        }

        throw const _DownloadCancelled();
      }

      _checkCancelled(downloadId);

      pipeSink = File(pipePath).openWrite();

      final writer = _OrderedPipeWriter(
        sink: pipeSink,
        downloadId: downloadId,
        waitIfPaused: _waitIfPaused,
        checkCancelled: _checkCancelled,
      );

      _updateProgress(
        downloadId,
        status: 'Đang tải và ghép video MP4...',
        completed: initialCompleted,
        total: segments.length,
        isDownloading: true,
        isPaused: false,
      );

      Future<void> worker() async {
        while (true) {
          await _waitIfPaused(downloadId);

          if (stopWorkers || _cancelRequested.contains(downloadId)) {
            return;
          }

          final currentIndex = nextIndex++;

          if (currentIndex >= segments.length) {
            return;
          }

          final segment = segments[currentIndex];

          final destination = _segmentFile(
            segmentsDirectory,
            segment.index,
          );

          try {
            final alreadyDownloaded =
                await destination.exists() &&
                    await destination.length() > 0;

            if (!alreadyDownloaded) {
              await _downloadSegment(
                downloadId: downloadId,
                client: client,
                headers: headers,
                segment: segment,
                destination: destination,
              );

              if (!_cancelRequested.contains(downloadId)) {
                completed++;
                onProgress(completed);
              }
            }

            _checkCancelled(downloadId);

            await writer.add(destination, segment.index);
          } on _DownloadCancelled {
            return;
          } catch (e) {
            if (_cancelRequested.contains(downloadId)) {
              return;
            }

            if (!firstErrorRecorded) {
              firstErrorRecorded = true;
              firstError = e;
            }

            stopWorkers = true;
            return;
          }
        }
      }

      await Future.wait(
        List.generate(workerCount, (_) => worker()),
      );

      _checkCancelled(downloadId);

      if (firstErrorRecorded) {
        throw Exception(
          'Không thể tải hoặc chuyển segment vào FFmpeg: $firstError',
        );
      }

      await writer.finish(segments.length);

      _checkCancelled(downloadId);

      await closePipeWriter();

      // Chờ FFmpeg hoàn tất hoặc nhận tín hiệu hủy.
      // Không phải chờ hết thời gian 3 phút nếu người dùng đã hủy.
      final cancelCompleter = _cancelCompleters[downloadId];

      final completedSession = await Future.any<dynamic>([
        ffmpegCompleted.future.timeout(
          _ffmpegFinishTimeout,
          onTimeout: () {
            throw TimeoutException(
              'FFmpeg không hoàn tất quá thời gian chờ.',
            );
          },
        ),
        if (cancelCompleter != null)
          cancelCompleter.future.then<dynamic>((_) {
            throw const _DownloadCancelled();
          }),
      ]);

      _checkCancelled(downloadId);

      final returnCode = await completedSession.getReturnCode();
      final returnCodeValue = returnCode?.getValue();

      if (returnCodeValue != 0) {
        final output = await completedSession.getOutput();

        throw Exception(
          'FFmpeg không thể ghép video. '
              '${output?.trim().isNotEmpty == true ? output : returnCode}',
        );
      }

      _checkCancelled(downloadId);

      if (!await temporaryVideo.exists() ||
          await temporaryVideo.length() < 1024) {
        throw Exception('File MP4 sau khi ghép không hợp lệ.');
      }

      _checkCancelled(downloadId);

      if (await videoFile.exists()) {
        await videoFile.delete();
      }

      await temporaryVideo.rename(videoFile.path);

      ffmpegFinishedNormally = true;

      await releasePipe();
    } catch (_) {
      stopWorkers = true;

      await stopFfmpeg();

      if (!_preserveEpisodeDirectory.contains(downloadId) &&
          await temporaryVideo.exists()) {
        try {
          await temporaryVideo.delete();
        } catch (e) {
          debugPrint('Không thể xóa file MP4 tạm: $e');
        }
      }

      rethrow;
    } finally {
      if (!ffmpegFinishedNormally &&
          !_preserveEpisodeDirectory.contains(downloadId)) {
        await releasePipe();
      }

      _ffmpegSessionIds.remove(downloadId);
    }
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

      final bandwidthMatch =
      RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);

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
