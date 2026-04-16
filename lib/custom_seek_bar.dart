import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// A custom seek bar for media_kit [Player] with smooth dragging,
/// buffer indicator, and time-bubble preview while seeking.
class CustomSeekBar extends StatefulWidget {
  final Player player;

  /// Height of the progress track (not dragging).
  final double trackHeight;

  /// Height of the progress track while dragging.
  final double activeTrackHeight;

  /// Diameter of the thumb.
  final double thumbSize;

  /// Diameter of the thumb while dragging.
  final double activeThumbSize;

  /// Total height of the touch-target area.
  final double hitHeight;

  final Color? playedColor;
  final Color? bufferedColor;
  final Color? backgroundColor;
  final Color? thumbColor;

  const CustomSeekBar({
    super.key,
    required this.player,
    this.trackHeight = 3.0,
    this.activeTrackHeight = 5.0,
    this.thumbSize = 14.0,
    this.activeThumbSize = 20.0,
    this.hitHeight = 48.0,
    this.playedColor,
    this.bufferedColor,
    this.backgroundColor,
    this.thumbColor,
  });

  @override
  State<CustomSeekBar> createState() => _CustomSeekBarState();
}

class _CustomSeekBarState extends State<CustomSeekBar>
    with SingleTickerProviderStateMixin {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;

  /// While dragging, this holds the user's drag ratio (0..1).
  double? _dragValue;
  bool _isDragging = false;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    dev.log('[SeekBar] initState — subscribing to player streams');

    // Read current player state immediately (stream only fires on *change*)
    _position = widget.player.state.position;
    _duration = widget.player.state.duration;
    _buffer = widget.player.state.buffer;
    dev.log('[SeekBar] initState — initial state: pos=${_position.inMilliseconds}ms  dur=${_duration.inMilliseconds}ms');

    _subs.add(widget.player.stream.position.listen((p) {
      if (!_isDragging) {
        setState(() => _position = p);
      } else {
        dev.log('[SeekBar] position stream fired during drag, ignored: ${p.inMilliseconds}ms');
      }
    }));
    _subs.add(widget.player.stream.duration.listen((d) {
      dev.log('[SeekBar] duration updated: ${d.inMilliseconds}ms');
      setState(() => _duration = d);
    }));
    _subs.add(widget.player.stream.buffer.listen((b) {
      setState(() => _buffer = b);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  double get _currentRatio {
    if (_duration.inMilliseconds <= 0) return 0.0;
    if (_dragValue != null) return _dragValue!;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  double get _bufferRatio {
    if (_duration.inMilliseconds <= 0) return 0.0;
    return (_buffer.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  void _onDragStart(double dx, double maxWidth) {
    final ratio = (dx / maxWidth).clamp(0.0, 1.0);
    dev.log('[SeekBar] DRAG_START  dx=$dx  maxWidth=$maxWidth  ratio=${ratio.toStringAsFixed(4)}');
    setState(() {
      _isDragging = true;
      _dragValue = ratio;
    });
  }

  void _onDragUpdate(double dx, double maxWidth) {
    final ratio = (dx / maxWidth).clamp(0.0, 1.0);
    dev.log('[SeekBar] DRAG_UPDATE dx=$dx  ratio=${ratio.toStringAsFixed(4)}  _isDragging=$_isDragging');
    setState(() {
      _dragValue = ratio;
    });
  }

  void _onDragEnd() {
    dev.log('[SeekBar] DRAG_END  _dragValue=$_dragValue  duration=${_duration.inMilliseconds}ms');
    if (_dragValue != null && _duration.inMilliseconds > 0) {
      final target = Duration(
        milliseconds: (_dragValue! * _duration.inMilliseconds).round(),
      );
      dev.log('[SeekBar] >>> player.seek(${target.inMilliseconds}ms)');
      widget.player.seek(target);
    } else {
      dev.log('[SeekBar] DRAG_END — skipped seek (dragValue=$_dragValue, duration=${_duration.inMilliseconds}ms)');
    }
    setState(() {
      _isDragging = false;
      _dragValue = null;
    });
  }

  void _onTap(double dx, double maxWidth) {
    dev.log('[SeekBar] TAP  dx=$dx  maxWidth=$maxWidth');
    if (_duration.inMilliseconds <= 0) {
      dev.log('[SeekBar] TAP — ignored, duration is 0');
      return;
    }
    final ratio = (dx / maxWidth).clamp(0.0, 1.0);
    final target = Duration(
      milliseconds: (ratio * _duration.inMilliseconds).round(),
    );
    dev.log('[SeekBar] TAP >>> player.seek(${target.inMilliseconds}ms)  ratio=${ratio.toStringAsFixed(4)}');
    widget.player.seek(target);
  }

  @override
  Widget build(BuildContext context) {
    dev.log('[SeekBar] build — _isDragging=$_isDragging  _dragValue=$_dragValue  '
        'ratio=${_currentRatio.toStringAsFixed(4)}  '
        'pos=${_position.inMilliseconds}ms  dur=${_duration.inMilliseconds}ms');

    final theme = Theme.of(context);
    final played = widget.playedColor ?? theme.colorScheme.primary;
    final buffered =
        widget.bufferedColor ?? theme.colorScheme.primary.withOpacity(0.3);
    final bg = widget.backgroundColor ?? Colors.white24;
    final thumb = widget.thumbColor ?? theme.colorScheme.primary;

    final currentTrackH =
    _isDragging ? widget.activeTrackHeight : widget.trackHeight;
    final currentThumbD =
    _isDragging ? widget.activeThumbSize : widget.thumbSize;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Time bubble shown while dragging
        if (_isDragging && _dragValue != null)
          _TimeBubble(
            text: _formatDuration(
              Duration(
                milliseconds:
                (_dragValue! * _duration.inMilliseconds).round(),
              ),
            ),
          ),

        // Seek bar
        LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (details) =>
                  _onDragStart(details.localPosition.dx, maxW),
              onHorizontalDragUpdate: (details) =>
                  _onDragUpdate(details.localPosition.dx, maxW),
              onHorizontalDragEnd: (_) => _onDragEnd(),
              onTapUp: (details) => _onTap(details.localPosition.dx, maxW),
              child: SizedBox(
                height: widget.hitHeight,
                width: maxW,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    // Background track
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      height: currentTrackH,
                      width: maxW,
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(currentTrackH / 2),
                      ),
                    ),

                    // Buffer track
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      height: currentTrackH,
                      width: maxW * _bufferRatio,
                      decoration: BoxDecoration(
                        color: buffered,
                        borderRadius: BorderRadius.circular(currentTrackH / 2),
                      ),
                    ),

                    // Played track
                    AnimatedContainer(
                      duration:
                      _isDragging
                          ? Duration.zero
                          : const Duration(milliseconds: 120),
                      height: currentTrackH,
                      width: maxW * _currentRatio,
                      decoration: BoxDecoration(
                        color: played,
                        borderRadius: BorderRadius.circular(currentTrackH / 2),
                      ),
                    ),

                    // Thumb
                    Positioned(
                      left: (maxW * _currentRatio) - currentThumbD / 2,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: currentThumbD,
                        height: currentThumbD,
                        decoration: BoxDecoration(
                          color: thumb,
                          shape: BoxShape.circle,
                          boxShadow: _isDragging
                              ? [
                            BoxShadow(
                              color: thumb.withOpacity(0.4),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ]
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),

        // Time labels
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_position),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
              Text(
                _formatDuration(_duration),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Floating bubble that shows the seek-target time while dragging.
class _TimeBubble extends StatelessWidget {
  final String text;

  const _TimeBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}