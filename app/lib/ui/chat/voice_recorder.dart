import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A finished voice recording.
class VoiceClip {
  VoiceClip(this.bytes, this.filename, this.mime, this.durationMs);
  final Uint8List bytes;
  final String filename;
  final String mime;
  final int durationMs;
}

class MicPermissionDenied implements Exception {}

/// Thin wrapper around `record` that returns bytes on every platform.
///
/// AAC/M4A is preferred everywhere (plays on iOS, Android and all browsers);
/// browsers that cannot record AAC fall back to Opus/WebM.
class VoiceRecorder {
  // Created lazily: the constructor talks to the platform plugin.
  AudioRecorder? _recorder;
  AudioRecorder get _rec => _recorder ??= AudioRecorder();
  DateTime? _startedAt;
  AudioEncoder _encoder = AudioEncoder.aacLc;

  bool get isRecording => _startedAt != null;

  Future<void> start() async {
    if (!await _rec.hasPermission()) throw MicPermissionDenied();
    _encoder = AudioEncoder.aacLc;
    if (kIsWeb && !await _rec.isEncoderSupported(AudioEncoder.aacLc)) {
      _encoder = AudioEncoder.opus;
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    var path = 'voice_$ts.${_ext()}';
    if (!kIsWeb) {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/$path';
    }
    await _rec.start(
      RecordConfig(encoder: _encoder, bitRate: 64000, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    _startedAt = DateTime.now();
  }

  String _ext() => _encoder == AudioEncoder.opus ? 'webm' : 'm4a';
  String _mime() => _encoder == AudioEncoder.opus ? 'audio/webm' : 'audio/mp4';

  /// Stops and returns the clip, or null if nothing usable was recorded.
  Future<VoiceClip?> stop() async {
    final started = _startedAt;
    _startedAt = null;
    final path = await _rec.stop();
    if (started == null || path == null) return null;
    final ms = DateTime.now().difference(started).inMilliseconds;
    final bytes = await XFile(path).readAsBytes();
    if (bytes.isEmpty) return null;
    return VoiceClip(bytes, 'voice.${_ext()}', _mime(), ms);
  }

  Future<void> cancel() async {
    _startedAt = null;
    if (_recorder == null) return;
    try {
      await _recorder!.cancel();
    } catch (_) {}
  }

  Future<void> dispose() async {
    final r = _recorder;
    _recorder = null;
    if (r == null) return;
    _startedAt = null;
    try {
      await r.dispose();
    } catch (_) {}
  }
}
