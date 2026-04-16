import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

class DownloadManager {
  static const _stateFileName = 'download_state.json';
  static const _segmentsDirName = 'segments';

  final Dio _dio = Dio();

  String? _downloadDir;
  List<String> _segments = [];
  int _completedCount = 0;
  bool _isCancelled = false;

  bool get hasIncompleteTask => _completedCount > 0 && !isComplete;
  bool get isComplete =>
      _segments.isNotEmpty && _completedCount >= _segments.length;
  int get completedCount => _completedCount;
  int get totalCount => _segments.length;

  Future<String> get _basePath async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/m3u8_download';
  }

  /// Check if there's a previous incomplete download.
  Future<bool> checkIncompleteDownload() async {
    final base = await _basePath;
    final stateFile = File('$base/$_stateFileName');
    if (!stateFile.existsSync()) return false;

    try {
      final json = jsonDecode(await stateFile.readAsString());
      final segments = List<String>.from(json['segments']);
      final segDir = Directory('$base/$_segmentsDirName');
      if (!segDir.existsSync()) return false;

      var completed = 0;
      for (var i = 0; i < segments.length; i++) {
        if (File('${segDir.path}/$i.ts').existsSync()) {
          completed++;
        }
      }

      _downloadDir = base;
      _segments = segments;
      _completedCount = completed;

      return completed < segments.length;
    } catch (_) {
      return false;
    }
  }

  /// Parse M3U8 and prepare a fresh download (or resume existing).
  Future<void> prepare(String m3u8Url, {bool fresh = false}) async {
    final base = await _basePath;
    _downloadDir = base;

    if (!fresh) {
      final hasIncomplete = await checkIncompleteDownload();
      if (hasIncomplete) return; // ready to resume
    }

    // Fresh download — clean up old data
    final dir = Directory(base);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    Directory('$base/$_segmentsDirName').createSync();

    // Parse M3U8
    final response = await _dio.get<String>(m3u8Url);
    final content = response.data!;
    final baseUrl = m3u8Url.substring(0, m3u8Url.lastIndexOf('/') + 1);

    _segments = [];
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (trimmed.startsWith('http')) {
        _segments.add(trimmed);
      } else {
        _segments.add('$baseUrl$trimmed');
      }
    }

    _completedCount = 0;
    _isCancelled = false;

    // Persist state
    await _saveState(m3u8Url);
  }

  /// Download all remaining segments. Calls [onProgress] after each segment.
  Future<void> download({
    required void Function(int completed, int total) onProgress,
  }) async {
    _isCancelled = false;
    final segDir = '$_downloadDir/$_segmentsDirName';

    for (var i = 0; i < _segments.length; i++) {
      if (_isCancelled) return;

      final segFile = File('$segDir/$i.ts');
      if (segFile.existsSync()) {
        // Already downloaded — skip
        _completedCount = i + 1;
        onProgress(_completedCount, _segments.length);
        continue;
      }

      // Download to a temp file first, then rename — ensures atomic writes
      final tmpFile = File('$segDir/$i.ts.tmp');
      await _dio.download(_segments[i], tmpFile.path);
      await tmpFile.rename(segFile.path);

      _completedCount = i + 1;
      onProgress(_completedCount, _segments.length);
    }
  }

  /// Merge all downloaded segments into a single .ts file, then remux to .mp4.
  ///
  /// The remux step (`-c copy -movflags +faststart`) creates a proper MP4
  /// container with a seek index (moov atom) at the front. This eliminates
  /// the grey-screen delay on seek because the player can instantly locate
  /// the nearest keyframe instead of scanning from the start of the TS stream.
  Future<String> merge() async {
    final segDir = '$_downloadDir/$_segmentsDirName';
    final tsPath = '$_downloadDir/video.ts';
    final mp4Path = '$_downloadDir/video.mp4';

    // Step 1: Concatenate .ts segments into one .ts file
    dev.log('[DownloadManager] merging ${_segments.length} segments → $tsPath');
    final tsFile = File(tsPath);
    final sink = tsFile.openWrite();

    for (var i = 0; i < _segments.length; i++) {
      final segFile = File('$segDir/$i.ts');
      sink.add(await segFile.readAsBytes());
    }

    await sink.flush();
    await sink.close();

    // Step 2: Remux .ts → .mp4 with faststart (moves moov atom to front)
    // -c copy = no re-encoding, just repackage (takes seconds)
    // -movflags +faststart = seek index at file beginning
    // -fflags +genpts+discardcorrupt = handle HLS timestamp discontinuities
    dev.log('[DownloadManager] remuxing $tsPath → $mp4Path');
    final session = await FFmpegKit.execute(
      '-i "$tsPath" -c copy -movflags +faststart -fflags +genpts+discardcorrupt -y "$mp4Path"',
    );

    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) {
      dev.log('[DownloadManager] remux succeeded');

      // Clean up: remove .ts, segments, and state file
      tsFile.deleteSync();
      Directory(segDir).deleteSync(recursive: true);
      File('$_downloadDir/$_stateFileName').deleteSync();

      return mp4Path;
    } else {
      // If remux fails, fall back to .ts file
      final logs = await session.getAllLogsAsString();
      dev.log('[DownloadManager] remux FAILED (rc=$returnCode): $logs');
      dev.log('[DownloadManager] falling back to .ts playback');

      Directory(segDir).deleteSync(recursive: true);
      File('$_downloadDir/$_stateFileName').deleteSync();

      return tsPath;
    }
  }

  /// Returns the path to the local video file if it exists.
  /// Prefers .mp4 (remuxed) over .ts (raw merge).
  Future<String?> getLocalVideoPath() async {
    final base = await _basePath;

    // Prefer .mp4 (has proper seek index)
    final mp4 = File('$base/video.mp4');
    if (mp4.existsSync()) return mp4.path;

    // Fall back to .ts
    final ts = File('$base/video.ts');
    if (ts.existsSync()) return ts.path;

    return null;
  }

  void cancel() {
    _isCancelled = true;
  }

  Future<void> _saveState(String m3u8Url) async {
    final stateFile = File('$_downloadDir/$_stateFileName');
    await stateFile.writeAsString(jsonEncode({
      'url': m3u8Url,
      'segments': _segments,
    }));
  }
}