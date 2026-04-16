import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'custom_seek_bar.dart';
import 'download_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Unlock all orientations so auto-rotate works
  SystemChrome.setPreferredOrientations([]);
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

  /// Prevents double-pushing the fullscreen route
  bool _fullscreenActive = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);

    _player.stream.playing.listen((playing) {
      if (mounted) dev.log('[Main] playing stream: $playing');
    });

    _player.stream.position.listen((p) {
      if (p.inMilliseconds % 2000 < 100) {
        dev.log('[Main] position: ${p.inMilliseconds}ms');
      }
    });

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

  /// [manual] = true  → user pressed the button: force landscape, restore portrait on exit
  /// [manual] = false → device auto-rotated: don't lock orientation, unlock all on exit
  void _enterFullscreen({bool manual = false}) {
    if (_fullscreenActive) return;
    _fullscreenActive = true;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (manual) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullscreenPage(
          player: _player,
          controller: _controller,
          restorePortrait: manual,
        ),
      ),
    ).then((_) {
      _fullscreenActive = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (manual) {
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      } else {
        // Unlock all orientations so normal auto-rotate continues to work
        SystemChrome.setPreferredOrientations([]);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Auto-enter fullscreen when device rotates to landscape
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape && !_fullscreenActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_fullscreenActive) {
          _enterFullscreen(manual: false);
        }
      });
    }

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
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _VideoStack(
                player: _player,
                controller: _controller,
                isFullscreen: false,
                onToggleFullscreen: () => _enterFullscreen(manual: true),
              ),
            ),

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

// ---------------------------------------------------------------------------
// Fullscreen page
// ---------------------------------------------------------------------------

class _FullscreenPage extends StatefulWidget {
  const _FullscreenPage({
    required this.player,
    required this.controller,
    required this.restorePortrait,
  });

  final Player player;
  final VideoController controller;

  /// true  → entered via button (orientation was forced); exit button forces portrait
  /// false → entered via auto-rotate; rotate back to portrait to exit
  final bool restorePortrait;

  @override
  State<_FullscreenPage> createState() => _FullscreenPageState();
}

class _FullscreenPageState extends State<_FullscreenPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// When the device physically rotates back to portrait (auto-rotate scenario),
  /// pop the fullscreen page automatically.
  @override
  void didChangeMetrics() {
    if (!widget.restorePortrait && mounted) {
      final view =
          WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      if (view != null) {
        final size = view.physicalSize;
        final isPortrait = size.height > size.width;
        if (isPortrait) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _VideoStack(
        player: widget.player,
        controller: widget.controller,
        isFullscreen: true,
        onToggleFullscreen: () {
          // Always restore portrait when user manually exits via button
          SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
          Navigator.pop(context);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared video stack (controls, gestures, overlays)
// ---------------------------------------------------------------------------

class _VideoStack extends StatefulWidget {
  const _VideoStack({
    required this.player,
    required this.controller,
    required this.isFullscreen,
    required this.onToggleFullscreen,
  });

  final Player player;
  final VideoController controller;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;

  @override
  State<_VideoStack> createState() => _VideoStackState();
}

class _VideoStackState extends State<_VideoStack> {
  bool _isPlaying = false;
  bool _showControls = true;
  bool _showSeekLeft = false;
  bool _showSeekRight = false;

  late final StreamSubscription<bool> _playingSub;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.player.state.playing;
    _playingSub = widget.player.stream.playing.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });
  }

  @override
  void dispose() {
    _playingSub.cancel();
    super.dispose();
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  void _togglePlayPause() => widget.player.playOrPause();

  Future<void> _seekForward() async {
    final pos = widget.player.state.position;
    final dur = widget.player.state.duration;
    final target = pos + const Duration(seconds: 15);
    await widget.player.seek(target > dur ? dur : target);
    setState(() => _showSeekRight = true);
    await Future.delayed(const Duration(milliseconds: 700));
    if (mounted) setState(() => _showSeekRight = false);
  }

  Future<void> _seekBackward() async {
    final pos = widget.player.state.position;
    final target = pos - const Duration(seconds: 15);
    await widget.player.seek(target < Duration.zero ? Duration.zero : target);
    setState(() => _showSeekLeft = true);
    await Future.delayed(const Duration(milliseconds: 700));
    if (mounted) setState(() => _showSeekLeft = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Raw video — no built-in controls
        Video(
          controller: widget.controller,
          controls: NoVideoControls,
        ),

        // Left half: tap toggles controls, double tap seeks -15s
        Positioned(
          left: 0,
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

        // Right half: tap toggles controls, double tap seeks +15s
        Positioned(
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
              child: _SeekOverlay(icon: Icons.fast_rewind, label: '-15秒'),
            ),
          ),

        // Seek forward overlay
        if (_showSeekRight)
          Positioned(
            right: 16,
            top: 0,
            bottom: 80,
            child: Center(
              child: _SeekOverlay(icon: Icons.fast_forward, label: '+15秒'),
            ),
          ),

        // Bottom gradient
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
                decoration: const BoxDecoration(
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

        // Fullscreen toggle button (top-right)
        if (_showControls)
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: widget.onToggleFullscreen,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.all(4),
                child: Icon(
                  widget.isFullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),

        // Seek bar — ALWAYS mounted to preserve duration state
        Positioned(
          left: 12,
          right: 12,
          bottom: 4,
          child: IgnorePointer(
            ignoring: !_showControls,
            child: AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: CustomSeekBar(player: widget.player),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Seek overlay widget
// ---------------------------------------------------------------------------

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
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}
