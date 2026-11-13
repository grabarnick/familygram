import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../format.dart';
import '../call/call_controller.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'chat_utils.dart';
import 'composer.dart';
import 'message_bubble.dart';

/// Conversation screen. With [embedded] it is shown in the right pane of the
/// wide (web/tablet) layout and has no back button.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.embedded = false});

  final int chatId;
  final bool embedded;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// One row of the reversed list: a message or a date chip.
class _Entry {
  _Entry.message(this.index) : dateMs = null;
  _Entry.date(int ms) : dateMs = ms, index = -1;
  final int index;
  final int? dateMs;
}

class _ChatScreenState extends State<ChatScreen> {
  late final AppStore _store = context.read<AppStore>();
  final _scroll = ScrollController();
  final _composerKey = GlobalKey<ComposerState>();
  final Map<String, GlobalKey> _keys = {};
  Message? _replyTo;
  String? _highlight;
  Timer? _highlightTimer;
  bool _showDown = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open(widget.chatId));
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId) {
      _store.closeChat(oldWidget.chatId);
      _replyTo = null;
      _highlight = null;
      _keys.clear();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _open(widget.chatId);
    }
  }

  void _open(int chatId) {
    if (!mounted) return;
    _store.openChat(chatId).catchError((_) {});
  }

  @override
  void dispose() {
    _store.closeChat(widget.chatId);
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final p = _scroll.position;
    if (p.pixels > p.maxScrollExtent - 400) {
      final cm = _store.messagesOf(widget.chatId);
      if (cm.loaded && cm.hasMore && !cm.loading) {
        _store.loadMore(widget.chatId).catchError((_) {});
      }
    }
    final down = p.pixels > 600;
    if (down != _showDown) setState(() => _showDown = down);
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _reply(Message m) {
    if (m.isLocal || m.deleted) return;
    setState(() => _replyTo = m);
    _composerKey.currentState?.focus();
  }

  Future<void> _jumpTo(int messageId) async {
    final items = _store.messagesOf(widget.chatId).items;
    final target = items
        .where((m) => !m.isLocal && m.id == messageId)
        .firstOrNull;
    if (target == null) {
      _snack('Сообщение не загружено');
      return;
    }
    final key = _keys[target.clientId];
    // Lazily built list: scroll up until the target is laid out.
    for (
      var i = 0;
      i < 30 && key?.currentContext == null && _scroll.hasClients;
      i++
    ) {
      final p = _scroll.position;
      final next = (p.pixels + p.viewportDimension * 0.8).clamp(
        0.0,
        p.maxScrollExtent,
      );
      if (next == p.pixels) break;
      _scroll.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
    final ctx = key?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 250),
    );
    setState(() => _highlight = target.clientId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  // -------------------------------------------------------------- actions ---

  Future<void> _showActions(Message m, {Offset? at}) async {
    final mine = m.senderId == _store.me?.id;
    final actions = <(String, IconData, String)>[
      if (m.state == SendState.failed) ('retry', Icons.refresh, 'Повторить'),
      if (!m.isLocal && !m.deleted) ('reply', Icons.reply, 'Ответить'),
      if (!m.deleted && m.text.trim().isNotEmpty)
        ('copy', Icons.copy, 'Копировать'),
      if (mine && !m.deleted && m.state != SendState.pending)
        ('delete', Icons.delete_outline, 'Удалить'),
    ];
    if (actions.isEmpty) return;

    String? choice;
    if (at != null) {
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox;
      choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          at & const Size(1, 1),
          Offset.zero & overlay.size,
        ),
        items: [
          for (final a in actions)
            PopupMenuItem(
              value: a.$1,
              child: Row(
                children: [
                  Icon(
                    a.$2,
                    size: 20,
                    color: a.$1 == 'delete' ? Fg.danger : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    a.$3,
                    style: TextStyle(
                      color: a.$1 == 'delete' ? Fg.danger : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    } else {
      HapticFeedback.selectionClick();
      choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final a in actions)
                ListTile(
                  leading: Icon(
                    a.$2,
                    color: a.$1 == 'delete' ? Fg.danger : null,
                  ),
                  title: Text(
                    a.$3,
                    style: TextStyle(
                      color: a.$1 == 'delete' ? Fg.danger : null,
                    ),
                  ),
                  onTap: () => Navigator.pop(ctx, a.$1),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    }
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'retry':
        unawaited(_store.retry(m));
      case 'reply':
        _reply(m);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) _snack('Скопировано');
      case 'delete':
        await _confirmDelete(m);
    }
  }

  Future<void> _confirmDelete(Message m) async {
    if (!m.isLocal) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Удалить сообщение?'),
          content: const Text('Оно исчезнет у всех участников чата.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Fg.danger),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await _store.deleteMessage(m);
      if (_replyTo?.clientId == m.clientId && mounted) {
        setState(() => _replyTo = null);
      }
    } catch (_) {
      if (mounted) _snack('Не удалось удалить сообщение');
    }
  }

  // ---------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chat = store.chatById(widget.chatId);
    final cm = store.messagesOf(widget.chatId);

    return Scaffold(
      appBar: _header(context, store, chat),
      body: ColoredBox(
        color: context.chatBg,
        child: Column(
          children: [
            if (store.liveCalls[widget.chatId] case final live?
                when live.state == CallState.active &&
                    !live.participantIds.contains(store.me?.id) &&
                    store.activeCall?.id != live.id)
              _JoinCallBanner(call: live),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _list(context, store, chat, cm)),
                  if (_showDown)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: FloatingActionButton.small(
                        heroTag: null,
                        tooltip: 'Вниз',
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        foregroundColor: context.secondaryText,
                        onPressed: _scrollToBottom,
                        child: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                    ),
                ],
              ),
            ),
            Composer(
              key: _composerKey,
              chatId: widget.chatId,
              replyTo: _replyTo,
              onCancelReply: () => setState(() => _replyTo = null),
              onSent: () {
                if (_replyTo != null) setState(() => _replyTo = null);
                _scrollToBottom();
              },
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _header(
    BuildContext context,
    AppStore store,
    Chat? chat,
  ) {
    final me = store.me;
    final scheme = Theme.of(context).colorScheme;
    int? otherId;
    if (chat != null && !chat.isGroup) {
      otherId = chat.memberIds.where((id) => id != me?.id).firstOrNull;
    }
    final other = otherId == null ? null : store.users[otherId];
    final typing = store.typingIn(widget.chatId);

    String subtitle = '';
    var subtitleAccent = false;
    if (typing.isNotEmpty) {
      subtitleAccent = true;
      subtitle = chat?.isGroup == true
          ? 'печатает: ${typing.map(store.userName).join(', ')}'
          : 'печатает…';
    } else if (chat?.isGroup == true) {
      subtitle = participants(chat!.memberIds.length);
    } else if (other != null) {
      subtitle = prettyPhone(other.phone);
    }

    final title = chat?.title ?? '';
    final callsOn = store.callsEnabled;
    // Nobody to call in the self chat ("Избранное").
    final canCall = (chat?.memberIds.length ?? 0) >= 2;
    const callsOffTip = 'Звонки не настроены на сервере';
    void call(bool video) =>
        CallController.start(context, widget.chatId, video: video);

    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: widget.embedded ? 16 : 0,
      leading: widget.embedded ? null : const BackButton(),
      title: Row(
        children: [
          Avatar(
            name: title,
            seed: chat?.isGroup == true
                ? widget.chatId
                : (otherId ?? widget.chatId),
            fileId: chat?.isGroup == true
                ? chat?.avatarFileId
                : other?.avatarFileId,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: subtitleAccent
                          ? scheme.primary
                          : context.secondaryText,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (canCall)
          IconButton(
            tooltip: callsOn ? 'Аудиозвонок' : callsOffTip,
            icon: Icon(Icons.call_outlined, color: scheme.primary),
            onPressed: callsOn ? () => call(false) : null,
          ),
        if (canCall)
          IconButton(
            tooltip: callsOn ? 'Видеозвонок' : callsOffTip,
            icon: Icon(Icons.videocam_outlined, color: scheme.primary),
            onPressed: callsOn ? () => call(true) : null,
          ),
        const SizedBox(width: 4),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    AppStore store,
    Chat? chat,
    ChatMessages cm,
  ) {
    final items = cm.items;
    if (!cm.loaded && items.isEmpty) {
      return cm.loading
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    }
    if (items.isEmpty) {
      return Center(
        child: _ChipLabel(text: 'Сообщений пока нет — напишите первым'),
      );
    }

    final entries = <_Entry>[];
    for (var i = items.length - 1; i >= 0; i--) {
      entries.add(_Entry.message(i));
      if (i == 0 || !sameDay(items[i].createdAt, items[i - 1].createdAt)) {
        entries.add(_Entry.date(items[i].createdAt));
      }
    }
    final byId = {
      for (final m in items)
        if (!m.isLocal) m.id: m,
    };
    final meId = store.me?.id;
    final isGroup = chat?.isGroup ?? false;
    final othersRead = chat?.othersReadId ?? 0;
    final showLoader = cm.loading && cm.loaded;

    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: entries.length + (showLoader ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == entries.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final e = entries[i];
        if (e.dateMs != null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(child: _ChipLabel(text: dateChip(e.dateMs!))),
          );
        }
        final m = items[e.index];
        final prev = e.index > 0 ? items[e.index - 1] : null;
        final next = e.index < items.length - 1 ? items[e.index + 1] : null;
        bool close(Message? a, Message b) =>
            a != null &&
            a.senderId == b.senderId &&
            sameDay(a.createdAt, b.createdAt) &&
            (a.createdAt - b.createdAt).abs() < 5 * 60 * 1000;
        final withPrev = close(prev, m);
        final withNext = close(next, m);
        final mine = m.senderId == meId;
        final reply = m.replyToId == null ? null : byId[m.replyToId];

        final bubble = MessageBubble(
          message: m,
          mine: mine,
          read: mine && !m.isLocal && m.id <= othersRead,
          senderName: isGroup && !mine && !withPrev
              ? store.userName(m.senderId)
              : null,
          replyTo: reply,
          replyMissing: m.replyToId != null && reply == null,
          replyName: reply == null ? null : store.userName(reply.senderId),
          groupedWithPrev: withPrev,
          groupedWithNext: withNext,
          highlighted: _highlight == m.clientId,
          onReplyTap: m.replyToId == null ? null : () => _jumpTo(m.replyToId!),
          onFailedTap: () => _showActions(m),
        );

        final key = _keys.putIfAbsent(m.clientId, GlobalKey.new);
        Widget row = Padding(
          key: key,
          padding: EdgeInsets.fromLTRB(8, withPrev ? 2 : 8, 8, 0),
          child: Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: GestureDetector(
              onLongPress: () => _showActions(m),
              onSecondaryTapUp: (d) => _showActions(m, at: d.globalPosition),
              child: bubble,
            ),
          ),
        );
        if (isTouchPlatform && !m.isLocal && !m.deleted) {
          row = _SwipeToReply(onReply: () => _reply(m), child: row);
        }
        return row;
      },
    );
  }
}

/// Small rounded label on the chat background (dates, empty state).
class _ChipLabel extends StatelessWidget {
  const _ChipLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(
      color: context.isDark ? const Color(0xCC2A2C2B) : const Color(0xB3FFFFFF),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: context.isDark ? Colors.white70 : Fg.text,
      ),
    ),
  );
}

/// Drag a message to the left to reply (touch platforms).
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.onReply, required this.child});
  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _trigger = 56.0;
  double _dx = 0;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    final progress = (_dx.abs() / _trigger).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) {
        final nx = (_dx + d.delta.dx).clamp(-80.0, 0.0);
        final armed = nx.abs() >= _trigger;
        if (armed && !_armed) HapticFeedback.lightImpact();
        setState(() {
          _dx = nx;
          _armed = armed;
        });
      },
      onHorizontalDragEnd: (_) {
        if (_armed) widget.onReply();
        setState(() {
          _dx = 0;
          _armed = false;
        });
      },
      onHorizontalDragCancel: () => setState(() {
        _dx = 0;
        _armed = false;
      }),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          if (_dx != 0)
            Positioned(
              right: 12,
              child: Opacity(
                opacity: progress,
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.black26,
                  child: Icon(
                    Icons.reply,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}

/// "A call is going on in this chat" strip with a join button.
class _JoinCallBanner extends StatelessWidget {
  const _JoinCallBanner({required this.call});

  final Call call;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = call.participantIds.length;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(
              call.video ? Icons.videocam : Icons.call,
              color: scheme.primary,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                call.video ? 'Идёт видеозвонок · $n' : 'Идёт звонок · $n',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: () => CallController.join(context, call),
              child: const Text('Присоединиться'),
            ),
          ],
        ),
      ),
    );
  }
}
