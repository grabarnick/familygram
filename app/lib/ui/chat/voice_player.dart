import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

import '../format.dart';
import '../theme.dart';

/// Play button + pseudo-waveform + duration for a voice message.
class VoicePlayer extends StatefulWidget {
  const VoicePlayer({
    super.key,
    required this.seed,
    required this.durationMs,
    this.url,
    this.mine = false,
  });

  /// Used to generate a stable waveform shape.
  final String seed;
  final int durationMs;

  /// Null while the message is still uploading.
  final String? url;
  final bool mine;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  /// Only one voice message plays at a time.
  static _VoicePlayerState? _current;

  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  Duration _pos = Duration.zero;
  Duration? _dur;
  bool _playing = false;
  bool _loading = false;

  static const _bars = 28;
  late final List<double> _heights = _wave(widget.seed);

  static List<double> _wave(String seed) {
    var h = seed.hashCode & 0x7fffffff;
    return List.generate(_bars, (i) {
      h = (h * 1103515245 + 12345) & 0x7fffffff;
      final r = (h % 1000) / 1000.0;
      // Softer edges, louder middle.
      final env = 0.55 + 0.45 * (1 - ((i - _bars / 2).abs() / (_bars / 2)));
      return (0.25 + 0.75 * r) * env;
    });
  }

  Future<void> _toggle() async {
    if (widget.url == null) return;
    if (_playing) {
      await _player?.pause();
      return;
    }
    if (_current != null && _current != this) await _current!._player?.pause();
    _current = this;
    if (_player == null) {
      setState(() => _loading = true);
      final p = AudioPlayer();
      _player = p;
      _stateSub = p.playerStateStream.listen((s) {
        if (!mounted) return;
        if (s.processingState == ProcessingState.completed) {
          p.pause();
          p.seek(Duration.zero);
        }
        setState(() {
          _playing = s.playing && s.processingState != ProcessingState.completed;
          _loading = s.processingState == ProcessingState.loading ||
              s.processingState == ProcessingState.buffering;
        });
      });
      _posSub = p.positionStream.listen((d) {
        if (mounted) setState(() => _pos = d);
      });
      try {
        _dur = await p.setUrl(widget.url!);
      } catch (_) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Не удалось воспроизвести голосовое')));
        }
        await _disposePlayer();
        return;
      }
    }
    unawaited(_player!.play());
  }

  Future<void> _disposePlayer() async {
    await _stateSub?.cancel();
    await _posSub?.cancel();
    await _player?.dispose();
    _player = null;
    _stateSub = null;
    _posSub = null;
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    _disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final totalMs = (_dur?.inMilliseconds ?? 0) > 0
        ? _dur!.inMilliseconds
        : widget.durationMs;
    final progress =
        totalMs > 0 ? (_pos.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    final shownMs = (_playing || _pos > Duration.zero) ? _pos.inMilliseconds : totalMs;
    final idle = context.secondaryText.withValues(alpha: 0.45);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: Material(
            color: accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.url == null ? null : _toggle,
              child: Center(
                child: (_loading || widget.url == null)
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(
                        _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 28,
                        semanticLabel: _playing ? 'Пауза' : 'Воспроизвести',
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 26,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < _bars; i++)
                    Container(
                      width: 3,
                      height: 4 + 22 * _heights[i],
                      margin: const EdgeInsets.only(right: 2),
                      decoration: BoxDecoration(
                        color: (i + 0.5) / _bars <= progress ? accent : idle,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              duration(shownMs),
              style: TextStyle(fontSize: 12, color: context.secondaryText),
            ),
          ],
        ),
      ],
    );
  }
}
