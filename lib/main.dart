import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'custom_seek_bar.dart';
import 'download_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'M3U8 Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const VideoPlayerPage(),
    );
  }
}

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  static const _testUrl =
      'https://69ca3a60e51acb0fd572b0a0--beamish-empanada-6d195f.netlify.app/output.m3u8';

  late final Player _player;
  late final VideoController _controller;
  final DownloadManager _downloadManager = DownloadManager();

  bool _isDownloading = false;
  bool _isLocal = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';

  // For play/pause overlay
  bool _isPlaying = false;
  bool _showControls = true;

  // For double-tap seek overlay
  bool _showSeekLeft = false;
  bool _showSeekRight = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);

    _player.stream.playing.listen((playing) {
      if (mounted) {
        dev.log('[Main] playing stream: $playing');
        setState(() => _isPlaying = playing);
      }
    });

    // Log position changes to see if seek takes effect
    _player.stream.position.listen((p) {
      // Only log occasionally to avoid spam — every 2 seconds
      if (p.inMilliseconds % 2000 < 100) {
        dev.log('[Main] position: ${p.inMilliseconds}ms');
      }
    });

    // Log errors from player
    _player.stream.error.listen((e) {
      dev.log('[Main] PLAYER ERROR: $e');
    });

    _initPlayback();
  }

  Future<void> _initPlayback() async {
    final localPath = await _downloadManager.getLocalVideoPath();
    if (localPath != null) {
      _player.open(Media(localPath));
      setState(() => _isLocal = true);
    } else {
      _player.open(Media(_testUrl));
    }
    _checkIncompleteDownload();
  }

  @override
  void dispose() {
    _downloadManager.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _checkIncompleteDownload() async {
    final hasIncomplete = await _downloadManager.checkIncompleteDownload();
    if (!hasIncomplete || !mounted) return;

    final completed = _downloadManager.completedCount;
    final total = _downloadManager.totalCount;

    final resume = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('發現未完成的下載'),
        content: Text('上次下載了 $completed / $total 個片段，是否繼續？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('繼續下載'),
          ),
        ],
      ),
    );

    if (resume == true) {
      _startDownload(resume: true);
    }
  }

  Future<void> _startDownload({bool resume = false}) async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadStatus = resume ? '準備續傳...' : '正在解析 M3U8...';
    });

    try {
      if (!resume) {
        await _downloadManager.prepare(_testUrl, fresh: true);
      }

      await _downloadManager.download(
        onProgress: (completed, total) {
          setState(() {
            _downloadProgress = completed / total;
            _downloadStatus = '下載片段 $completed / $total';
          });
        },
      );

      setState(() => _downloadStatus = '正在合併檔案...');

      final outputPath = await _downloadManager.merge();
      _player.open(Media(outputPath));

      setState(() {
        _downloadProgress = 1.0;
        _downloadStatus = '下載完成，已切換為本地播放';
        _isLocal = true;
      });
    } catch (e) {
      setState(() => _downloadStatus = '下載失敗：$e');
    } finally {
      setState(() => _isDownloading = false);
    }
  }

  void _toggleControls() {
    dev.log('[Main] toggleControls — was $_showControls');
    setState(() => _showControls = !_showControls);
  }

  void _togglePlayPause() {
    dev.log('[Main] togglePlayPause — was playing=$_isPlaying');
    _player.playOrPause();
  }

  Future<void> _seekForward() async {
    final pos = _player.state.position;
    final dur = _player.state.duration;
    final target = pos + const Duration(seconds: 15);
    await _player.seek(target > dur ? dur : target);
    setState(() => _showSeekRight = true);
    await Future.delayed(const Duration(milliseconds: 700));
    if (mounted) setState(() => _showSeekRight = false);
  }

  Future<void> _seekBackward() async {
    final pos = _player.state.position;
    final target = pos - const Duration(seconds: 15);
    await _player.seek(target < Duration.zero ? Duration.zero : target);
    setState(() => _showSeekLeft = true);
    await Future.delayed(const Duration(milliseconds: 700));
    if (mounted) setState(() => _showSeekLeft = false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isLocal ? 'M3U8 Player (本地)' : 'M3U8 Player (線上)'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            if (!_isLocal)
              IconButton(
                onPressed: _isDownloading ? null : () => _startDownload(),
                icon: const Icon(Icons.download),
                tooltip: '下載影片',
              ),
          ],
        ),
        body: Column(
          children: [
            // Video with custom controls
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                children: [
                  // Raw video — no built-in controls
                  Video(
                    controller: _controller,
                    controls: NoVideoControls,
                  ),

                  // Left half: single tap toggles controls, double tap seeks -15s
                  Positioned(
                    left: 0,
                    right: null,
                    top: 0,
                    bottom: 80,
                    child: SizedBox(
                      width: MediaQuery.of(context).size.width / 2,
                      child: GestureDetector(
                        onTap: _toggleControls,
                        onDoubleTap: _seekBackward,
                        behavior: HitTestBehavior.translucent,
                      ),
                    ),
                  ),

                  // Right half: single tap toggles controls, double tap seeks +15s
                  Positioned(
                    left: null,
                    right: 0,
                    top: 0,
                    bottom: 80,
                    child: SizedBox(
                      width: MediaQuery.of(context).size.width / 2,
                      child: GestureDetector(
                        onTap: _toggleControls,
                        onDoubleTap: _seekForward,
                        behavior: HitTestBehavior.translucent,
                      ),
                    ),
                  ),

                  // Seek backward overlay
                  if (_showSeekLeft)
                    Positioned(
                      left: 16,
                      top: 0,
                      bottom: 80,
                      child: Center(
                        child: _SeekOverlay(
                          icon: Icons.fast_rewind,
                          label: '-15秒',
                        ),
                      ),
                    ),

                  // Seek forward overlay
                  if (_showSeekRight)
                    Positioned(
                      right: 16,
                      top: 0,
                      bottom: 80,
                      child: Center(
                        child: _SeekOverlay(
                          icon: Icons.fast_forward,
                          label: '+15秒',
                        ),
                      ),
                    ),

                  // Semi-transparent gradient at the bottom (always behind seek bar)
                  if (_showControls)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 100,
                      child: IgnorePointer(
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black54],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Play/pause button centered
                  if (_showControls)
                    Center(
                      child: GestureDetector(
                        onTap: _togglePlayPause,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(12),
                          child: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                      ),
                    ),

                  // Seek bar — ALWAYS mounted to preserve duration state,
                  // use Opacity + IgnorePointer to hide/disable instead of
                  // removing from tree (which causes re-initState & loses duration)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 4,
                    child: IgnorePointer(
                      ignoring: !_showControls,
                      child: AnimatedOpacity(
                        opacity: _showControls ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: CustomSeekBar(
                          player: _player,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Download progress
            if (_isDownloading || _downloadStatus.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isDownloading)
                      LinearProgressIndicator(value: _downloadProgress),
                    const SizedBox(height: 4),
                    Text(
                      _downloadStatus,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),

            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _SeekOverlay extends StatelessWidget {
  const _SeekOverlay({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(40),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 32),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}