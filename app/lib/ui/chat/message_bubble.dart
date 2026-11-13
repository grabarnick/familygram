import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../format.dart';
import '../call/call_text.dart';
import '../theme.dart';
import 'chat_utils.dart';
import 'media_viewer.dart';
import 'voice_player.dart';

const _maxBubbleWidth = 340.0;
const _mediaWidth = 260.0;

/// One message: bubble with content, optional sender name, reply quote,
/// time and delivery ticks.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.read,
    this.senderName,
    this.replyTo,
    this.replyMissing = false,
    this.replyName,
    this.groupedWithPrev = false,
    this.groupedWithNext = false,
    this.highlighted = false,
    this.onReplyTap,
    this.onFailedTap,
  });

  final Message message;
  final bool mine;

  /// Others have read this message (for my own messages).
  final bool read;

  /// Shown above the content (incoming messages in groups).
  final String? senderName;
  final Message? replyTo;

  /// The message replies to something not loaded locally.
  final bool replyMissing;
  final String? replyName;
  final bool groupedWithPrev;
  final bool groupedWithNext;
  final bool highlighted;
  final VoidCallback? onReplyTap;
  final VoidCallback? onFailedTap;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final bg = mine ? context.bubbleOut : context.bubbleIn;
    const big = Radius.circular(18);
    const small = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: !mine && groupedWithPrev ? small : big,
      bottomLeft: !mine && groupedWithNext ? small : big,
      topRight: mine && groupedWithPrev ? small : big,
      bottomRight: mine && groupedWithNext ? small : big,
    );

    final isMedia = !m.deleted &&
        (m.kind == MessageKind.image || m.kind == MessageKind.video) &&
        m.file != null;
    final mediaOnly = isMedia && m.text.trim().isEmpty && m.replyToId == null &&
        senderName == null;

    final children = <Widget>[];
    if (senderName != null) {
      children.add(Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, isMedia ? 6 : 0),
        child: Text(
          senderName!,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: senderColor(m.senderId),
          ),
        ),
      ));
    }
    if (m.replyToId != null && !m.deleted) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: ReplyQuote(
          name: replyName ?? '',
          text: replyTo != null
              ? messageSnippet(replyTo!)
              : (replyMissing ? 'Сообщение' : ''),
          onTap: onReplyTap,
        ),
      ));
    }

    final meta = _Meta(message: m, mine: mine, read: read, onFailedTap: onFailedTap);

    if (m.deleted) {
      children.add(_textWithMeta(
        context,
        Text('Сообщение удалено',
            style: TextStyle(
                fontStyle: FontStyle.italic,
                fontSize: 15,
                color: context.secondaryText)),
        meta,
      ));
    } else {
      switch (m.kind) {
        case MessageKind.image:
        case MessageKind.video:
          if (m.file == null) break;
          final media = _MediaContent(
            message: m,
            mediaOnly: mediaOnly,
            radius: mediaOnly
                ? radius
                : BorderRadius.circular(12),
            meta: m.text.trim().isEmpty ? meta : null,
          );
          children.add(mediaOnly
              ? media
              : Padding(
                  padding: EdgeInsets.fromLTRB(
                      4, children.isEmpty ? 4 : 6, 4, m.text.trim().isEmpty ? 4 : 0),
                  child: media,
                ));
          if (m.text.trim().isNotEmpty) {
            children.add(_textWithMeta(context, LinkText(m.text), meta));
          }
        case MessageKind.voice:
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _voice(context),
                const SizedBox(width: 8),
                meta,
              ],
            ),
          ));
        case MessageKind.call:
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: CallMessageContent(message: m, mine: mine, meta: meta),
          ));
        case MessageKind.file:
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                FileTile(message: m),
                if (m.text.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                        alignment: Alignment.centerLeft, child: LinkText(m.text)),
                  ),
                const SizedBox(height: 2),
                meta,
              ],
            ),
          ));
        default:
          children.add(_textWithMeta(context, LinkText(m.text), meta));
      }
    }

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      constraints: BoxConstraints(
        maxWidth: isMedia ? _mediaWidth + 8 : _maxBubbleWidth,
      ),
      decoration: BoxDecoration(
        color: mediaOnly ? Colors.transparent : bg,
        borderRadius: radius,
        boxShadow: mediaOnly || context.isDark
            ? null
            : const [
                BoxShadow(
                    color: Color(0x14000000), blurRadius: 1, offset: Offset(0, 1)),
              ],
        border: highlighted
            ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
            : null,
      ),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
    return bubble;
  }

  Widget _voice(BuildContext context) {
    final f = message.file!;
    final api = context.read<AppStore>().api;
    return VoicePlayer(
      key: ValueKey('voice-${message.clientId}'),
      seed: f.id.isNotEmpty ? f.id : message.clientId,
      durationMs: f.durationMs,
      url: f.id.isEmpty || api == null ? null : api.fileUrl(f.id),
      mine: mine,
    );
  }

  /// Text with time/ticks tucked into the last line's bottom-right corner.
  Widget _textWithMeta(BuildContext context, Widget text, Widget meta) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
      child: Stack(
        children: [
          Padding(
            // Reserve room so the meta never overlaps the last line.
            padding: EdgeInsets.only(right: mine ? 62 : 42, bottom: 2),
            child: text,
          ),
          Positioned(right: 0, bottom: -2, child: meta),
        ],
      ),
    );
  }
}

/// Time + delivery ticks.
class _Meta extends StatelessWidget {
  const _Meta({
    required this.message,
    required this.mine,
    required this.read,
    this.onFailedTap,
    this.onMedia = false,
  });

  final Message message;
  final bool mine;
  final bool read;
  final bool onMedia;
  final VoidCallback? onFailedTap;

  @override
  Widget build(BuildContext context) {
    final color = onMedia ? Colors.white : context.secondaryText;
    final accent = onMedia ? Colors.white : Theme.of(context).colorScheme.primary;
    Widget? tick;
    if (mine) {
      switch (message.state) {
        case SendState.pending:
          tick = Icon(Icons.schedule, size: 14, color: color, semanticLabel: 'Отправляется');
        case SendState.failed:
          tick = InkWell(
            onTap: onFailedTap,
            child: const Icon(Icons.error, size: 16, color: Fg.danger,
                semanticLabel: 'Не отправлено, нажмите для повтора'),
          );
        case SendState.sent:
          tick = read
              ? Icon(Icons.done_all, size: 16, color: accent, semanticLabel: 'Прочитано')
              : Icon(Icons.done, size: 16, color: color, semanticLabel: 'Отправлено');
      }
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(bubbleTime(message.createdAt),
            style: TextStyle(fontSize: 12, color: color)),
        if (tick != null) ...[const SizedBox(width: 3), tick],
      ],
    );
  }
}

/// Quoted message inside a bubble or above the composer.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({super.key, required this.name, required this.text, this.onTap});

  final String name;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: accent.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accent, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: accent)),
              Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: context.secondaryText)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Image or video preview inside a bubble.
class _MediaContent extends StatelessWidget {
  const _MediaContent({
    required this.message,
    required this.mediaOnly,
    required this.radius,
    this.meta,
  });

  final Message message;
  final bool mediaOnly;
  final BorderRadius radius;
  final _Meta? meta;

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    final f = message.file!;
    final api = store.api;
    final local = store.pendingBytes(message);
    final url = f.id.isNotEmpty && api != null ? api.fileUrl(f.id) : null;
    final isVideo = message.kind == MessageKind.video;
    final aspect = (f.width > 0 && f.height > 0)
        ? (f.width / f.height).clamp(0.5, 2.2)
        : (isVideo ? 16 / 9 : 4 / 3);
    final heroTag = 'media-${message.clientId}';

    Widget content;
    if (isVideo) {
      content = Container(
        color: const Color(0xFF1F2523),
        alignment: Alignment.center,
        child: Container(
          width: 56,
          height: 56,
          decoration:
              const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
          child: url == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
        ),
      );
    } else if (local != null) {
      content = Image.memory(local, fit: BoxFit.cover, gaplessPlayback: true);
    } else if (url != null) {
      content = CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, _) => Container(color: context.secondaryText.withValues(alpha: 0.15)),
        errorWidget: (_, _, _) => Container(
          color: context.secondaryText.withValues(alpha: 0.15),
          alignment: Alignment.center,
          child: Icon(Icons.broken_image_outlined, color: context.secondaryText),
        ),
      );
    } else {
      content = Container(color: context.secondaryText.withValues(alpha: 0.15));
    }

    final showMeta = meta != null;
    return Semantics(
      label: isVideo ? 'Видео' : 'Фото',
      button: true,
      child: GestureDetector(
        onTap: () {
          if (isVideo) {
            if (url == null) return;
            Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => VideoViewer(url: url, title: f.name)));
          } else {
            if (url == null && local == null) return;
            Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ImageViewer(
                    heroTag: heroTag, url: url, bytes: url == null ? local : null, title: f.name)));
          }
        },
        child: ClipRRect(
          borderRadius: radius,
          child: SizedBox(
            width: _mediaWidth,
            child: AspectRatio(
              aspectRatio: aspect,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(tag: heroTag, child: content),
                  if (message.isLocal && !isVideo)
                    const Center(
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                            strokeWidth: 3, color: Colors.white),
                      ),
                    ),
                  if (isVideo && f.durationMs > 0)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _Pill(child: Text(duration(f.durationMs),
                          style: const TextStyle(color: Colors.white, fontSize: 12))),
                    ),
                  if (showMeta)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: _Pill(
                        child: _Meta(
                          message: meta!.message,
                          mine: meta!.mine,
                          read: meta!.read,
                          onFailedTap: meta!.onFailedTap,
                          onMedia: true,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: Colors.black54, borderRadius: BorderRadius.circular(10)),
        child: child,
      );
}

/// Document attachment row.
class FileTile extends StatelessWidget {
  const FileTile({super.key, required this.message});
  final Message message;

  static IconData iconFor(String mime, String name) {
    final n = name.toLowerCase();
    if (mime == 'application/pdf' || n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (n.endsWith('.zip') || n.endsWith('.rar') || n.endsWith('.7z')) {
      return Icons.folder_zip_outlined;
    }
    if (n.endsWith('.xls') || n.endsWith('.xlsx') || n.endsWith('.csv')) {
      return Icons.table_chart_outlined;
    }
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final f = message.file!;
    final api = context.read<AppStore>().api;
    final url = f.id.isNotEmpty && api != null ? api.fileUrl(f.id) : null;
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: url == null ? null : () => openExternally(context, url),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: url == null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Icon(iconFor(f.mime, f.name), color: Colors.white, size: 22),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(f.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(fileSize(f.size),
                    style: TextStyle(fontSize: 13, color: context.secondaryText)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Message text with clickable links. Selectable on web/desktop.
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key});
  final String text;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  static final _url = RegExp(
      r'''((?:https?://|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]])''',
      caseSensitive: false);
  final List<TapGestureRecognizer> _recognizers = [];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final base = TextStyle(
      fontSize: 16,
      height: 1.3,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final linkStyle = base.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _url.allMatches(widget.text)) {
      if (m.start > last) spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      final raw = m.group(0)!;
      final href = raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw;
      final r = TapGestureRecognizer()
        ..onTap = () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
      _recognizers.add(r);
      spans.add(TextSpan(text: raw, style: linkStyle, recognizer: r));
      last = m.end;
    }
    if (last < widget.text.length) spans.add(TextSpan(text: widget.text.substring(last)));
    final span = TextSpan(style: base, children: spans);
    return isTouchPlatform ? Text.rich(span) : SelectableText.rich(span);
  }
}

/// Content of a kind "call" message: icon + "Видеозвонок · 2:14".
class CallMessageContent extends StatelessWidget {
  const CallMessageContent({
    super.key,
    required this.message,
    required this.mine,
    this.meta,
  });

  final Message message;
  final bool mine;
  final Widget? meta;

  @override
  Widget build(BuildContext context) {
    final missed = callMessageMissed(message, outgoing: mine);
    final color = missed ? Theme.of(context).colorScheme.error : null;
    final video = message.call?.video ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Icon(
          missed
              ? Icons.call_missed
              : video
                  ? Icons.videocam_outlined
                  : Icons.call_outlined,
          size: 20,
          color: color ?? Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            callMessageText(message, outgoing: mine),
            style: TextStyle(fontSize: 15, color: color, fontWeight: FontWeight.w500),
          ),
        ),
        if (meta != null) ...[const SizedBox(width: 8), meta!],
      ],
    );
  }
}
