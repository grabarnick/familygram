import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../format.dart';
import '../theme.dart';
import 'chat_utils.dart';
import 'message_bubble.dart';
import 'voice_recorder.dart';

/// Bottom input bar: reply preview, attach, text field, send / hold-to-record.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.chatId,
    this.replyTo,
    this.onCancelReply,
    this.onSent,
  });

  final int chatId;
  final Message? replyTo;
  final VoidCallback? onCancelReply;

  /// Called after a message was handed to the store (clears reply, scrolls).
  final VoidCallback? onSent;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final _text = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  final _recorder = VoiceRecorder();
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _recording = false;
  bool _cancelling = false;

  bool get _hasText => _text.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId) _text.clear();
    if (widget.replyTo != null && oldWidget.replyTo?.clientId != widget.replyTo!.clientId) {
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Focus the text field (used by the chat screen when replying).
  void focus() => _focus.requestFocus();

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    // Enter sends on web/desktop; Shift+Enter inserts a newline.
    if (isTouchPlatform) return KeyEventResult.ignored;
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _sendText();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  AppStore get _store => context.read<AppStore>();

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _sendText() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _store.sendText(widget.chatId, t, replyToId: _replyId);
    _text.clear();
    widget.onSent?.call();
  }

  int? get _replyId {
    final r = widget.replyTo;
    return (r == null || r.isLocal) ? null : r.id;
  }

  // ---------------------------------------------------------- attachments ---

  Future<void> _showAttachSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Фото или видео'),
              onTap: () => Navigator.pop(ctx, 'media'),
            ),
            if (isTouchPlatform)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Камера'),
                onTap: () => Navigator.pop(ctx, 'camera'),
              ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Файл'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    try {
      switch (choice) {
        case 'media':
          await _pickMedia();
        case 'camera':
          final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85);
          if (x != null) await _sendBytes(await x.readAsBytes(), x.name, x.mimeType);
        case 'file':
          final files = await FilePicker.pickFiles();
          for (final f in files) {
            await _sendBytes(await f.readAsBytes(), f.name, null);
          }
      }
    } catch (e) {
      if (mounted) _snack('Не удалось прикрепить файл');
    }
  }

  Future<void> _pickMedia() async {
    if (kIsWeb || !isTouchPlatform) {
      final files = await FilePicker.pickFiles(type: FileType.media);
      for (final f in files) {
        await _sendBytes(await f.readAsBytes(), f.name, null);
      }
      return;
    }
    final items = await ImagePicker().pickMultipleMedia(imageQuality: 85);
    for (final x in items) {
      await _sendBytes(await x.readAsBytes(), x.name, x.mimeType);
    }
  }

  Future<void> _sendBytes(Uint8List bytes, String name, String? mime) async {
    if (!mounted) return;
    final type = mime ??
        lookupMimeType(name, headerBytes: bytes.length > 32 ? bytes.sublist(0, 32) : bytes) ??
        'application/octet-stream';
    int? w, h;
    if (type.startsWith('image/') && type != 'image/svg+xml') {
      try {
        final img = await decodeImageFromList(bytes);
        w = img.width;
        h = img.height;
        img.dispose();
      } catch (_) {}
    }
    unawaited(_store.sendFile(
      widget.chatId,
      bytes,
      filename: name,
      mime: type,
      width: w,
      height: h,
      replyToId: _replyId,
      voice: false,
    ).catchError((_) {}));
    widget.onSent?.call();
  }

  // ---------------------------------------------------------------- voice ---

  Future<void> _startRecording() async {
    if (_recording) return;
    try {
      await _recorder.start();
    } on MicPermissionDenied {
      if (mounted) _snack('Нет доступа к микрофону. Разрешите его в настройках.');
      return;
    } catch (_) {
      if (mounted) _snack('Не удалось начать запись');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _cancelling = false;
      _elapsed = Duration.zero;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() => _elapsed += const Duration(milliseconds: 200));
    });
  }

  Future<void> _finishRecording({required bool send}) async {
    if (!_recording) return;
    _ticker?.cancel();
    setState(() => _recording = false);
    if (!send) {
      await _recorder.cancel();
      return;
    }
    try {
      final clip = await _recorder.stop();
      if (clip == null || clip.durationMs < 700) {
        if (mounted) _snack('Удерживайте кнопку, чтобы записать голосовое');
        return;
      }
      if (!mounted) return;
      unawaited(_store.sendFile(
        widget.chatId,
        clip.bytes,
        filename: clip.filename,
        mime: clip.mime,
        voice: true,
        durationMs: clip.durationMs,
        replyToId: _replyId,
      ).catchError((_) {}));
      widget.onSent?.call();
    } catch (_) {
      if (mounted) _snack('Не удалось сохранить запись');
    }
  }

  // ---------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.watch<AppStore>();
    final reply = widget.replyTo;

    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reply != null && !_recording)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    Icon(Icons.reply, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ReplyQuote(
                        name: store.userName(reply.senderId),
                        text: messageSnippet(reply),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Отменить ответ',
                      icon: const Icon(Icons.close),
                      onPressed: widget.onCancelReply,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_recording)
                    Expanded(child: _recordingBar(context))
                  else ...[
                    IconButton(
                      tooltip: 'Прикрепить',
                      icon: Icon(Icons.attach_file, color: context.secondaryText),
                      onPressed: _showAttachSheet,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        onChanged: (_) => store.typing(widget.chatId),
                        decoration: InputDecoration(
                          hintText: 'Сообщение',
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  _hasText && !_recording ? _sendButton(scheme) : _micButton(scheme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendButton(ColorScheme scheme) => SizedBox(
        width: 44,
        height: 44,
        child: IconButton.filled(
          tooltip: 'Отправить',
          style: IconButton.styleFrom(backgroundColor: scheme.primary),
          icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
          onPressed: _sendText,
        ),
      );

  Widget _micButton(ColorScheme scheme) {
    return Semantics(
      button: true,
      label: 'Удерживайте, чтобы записать голосовое',
      child: GestureDetector(
        onTap: () => _snack('Удерживайте, чтобы записать голосовое'),
        onLongPressStart: (_) => _startRecording(),
        onLongPressMoveUpdate: (d) {
          final cancel = d.offsetFromOrigin.dx < -90;
          if (cancel != _cancelling) setState(() => _cancelling = cancel);
        },
        onLongPressEnd: (_) => _finishRecording(send: !_cancelling),
        onLongPressCancel: () => _finishRecording(send: false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: _recording ? 56 : 44,
          height: _recording ? 56 : 44,
          decoration: BoxDecoration(
            color: _recording
                ? (_cancelling ? Fg.danger : scheme.primary)
                : scheme.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            _cancelling ? Icons.delete_outline : Icons.mic_none_rounded,
            color: _recording ? Colors.white : scheme.primary,
            size: 26,
          ),
        ),
      ),
    );
  }

  Widget _recordingBar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 12),
          const _BlinkingDot(),
          const SizedBox(width: 8),
          Text(duration(_elapsed.inMilliseconds),
              style: const TextStyle(fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
          const Spacer(),
          Text(
            _cancelling ? 'Отпустите для отмены' : '‹ Влево — отмена',
            style: TextStyle(
                color: _cancelling ? Fg.danger : context.secondaryText, fontSize: 14),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _c,
        child: Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(color: Fg.danger, shape: BoxShape.circle),
        ),
      );
}
