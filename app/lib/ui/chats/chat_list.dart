import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../call/call_text.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'new_chat_screen.dart';

/// Chat list with header, search and rows (design: Main.dc.html).
class ChatListView extends StatefulWidget {
  const ChatListView({
    super.key,
    required this.onOpen,
    this.selectedChatId,
    this.extraActions = const [],
  });

  final void Function(int chatId) onOpen;

  /// Highlighted row (wide two-pane layout).
  final int? selectedChatId;

  /// Additional header buttons (wide layout: calls, settings).
  final List<Widget> extraActions;

  @override
  State<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends State<ChatListView> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _newChat() async {
    final id = await Navigator.of(context)
        .push<int>(MaterialPageRoute(builder: (_) => const NewChatScreen()));
    if (id != null) widget.onOpen(id);
  }

  Future<void> _refresh() async {
    final store = context.read<AppStore>();
    await Future.wait([store.refreshChats(), store.refreshUsers()]);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final q = _query.trim().toLowerCase();
    final chats = q.isEmpty
        ? store.chats
        : store.chats.where((c) => c.title.toLowerCase().contains(q)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(onNewChat: _newChat, extraActions: widget.extraActions),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: SizedBox(
            height: 40,
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              textAlignVertical: TextAlignVertical.center,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Поиск',
                prefixIcon: const Icon(Icons.search, size: 20),
                contentPadding: EdgeInsets.zero,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Очистить',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: chats.isEmpty
                ? _Empty(searching: q.isNotEmpty, onNewChat: _newChat)
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: chats.length,
                    itemBuilder: (_, i) => ChatRow(
                      chat: chats[i],
                      selected: chats[i].id == widget.selectedChatId,
                      onTap: () => widget.onOpen(chats[i].id),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onNewChat, required this.extraActions});

  final VoidCallback onNewChat;
  final List<Widget> extraActions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Чаты',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ),
          ...extraActions,
          const SizedBox(width: 4),
          IconButton.filledTonal(
            tooltip: 'Новый чат',
            onPressed: onNewChat,
            style: IconButton.styleFrom(
              backgroundColor: context.isDark
                  ? scheme.primary.withValues(alpha: 0.18)
                  : Fg.accentTint,
              foregroundColor: scheme.primary,
              fixedSize: const Size(44, 44),
            ),
            icon: const Icon(Icons.edit_outlined, size: 22),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.searching, required this.onNewChat});

  final bool searching;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    // Scrollable so pull-to-refresh still works when empty.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        Icon(
          searching ? Icons.search_off : Icons.chat_bubble_outline,
          size: 48,
          color: context.secondaryText,
        ),
        const SizedBox(height: 16),
        Text(
          searching ? 'Ничего не найдено' : 'Пока нет чатов',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        if (!searching) ...[
          const SizedBox(height: 8),
          Text(
            'Напишите кому-нибудь из семьи',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.secondaryText),
          ),
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
              onPressed: onNewChat,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Начать чат'),
            ),
          ),
        ],
      ],
    );
  }
}

/// One row of the chat list.
class ChatRow extends StatelessWidget {
  const ChatRow({
    super.key,
    required this.chat,
    required this.onTap,
    this.selected = false,
  });

  final Chat chat;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final meId = store.me?.id;
    final lm = chat.lastMessage;
    final mine = lm != null && lm.senderId == meId;

    // Direct chats show the other person's avatar.
    var avatarFile = chat.avatarFileId;
    var seed = chat.id;
    if (!chat.isGroup) {
      final other = chat.memberIds.firstWhere(
        (id) => id != meId,
        orElse: () => meId ?? 0,
      );
      seed = other;
      avatarFile ??= store.users[other]?.avatarFileId;
    }

    final typers = store.typingIn(chat.id);
    final secondary = context.secondaryText;

    Widget preview;
    if (typers.isNotEmpty) {
      final who = chat.isGroup ? '${store.userName(typers.first)} ' : '';
      preview = Text(
        '$whoпечатает…',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 15, color: scheme.primary),
      );
    } else {
      String prefix = '';
      if (lm != null && !lm.deleted) {
        if (mine) {
          prefix = 'Вы: ';
        } else if (chat.isGroup) {
          prefix = '${store.userName(lm.senderId)}: ';
        }
      }
      preview = Text.rich(
        TextSpan(
          children: [
            if (prefix.isNotEmpty)
              TextSpan(
                text: prefix,
                style: TextStyle(color: scheme.onSurface),
              ),
            TextSpan(text: previewText(lm)),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 15, color: secondary),
      );
    }

    final selectedBg = context.isDark
        ? scheme.primary.withValues(alpha: 0.16)
        : Fg.accentTint;

    return Material(
      color: selected ? selectedBg : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Avatar(
                  name: chat.title,
                  seed: seed,
                  fileId: avatarFile,
                  size: 54,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    height: 72,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color:
                              Theme.of(context).dividerTheme.color ??
                              Fg.divider,
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                chat.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (mine) ...[
                              _Ticks(chat: chat, message: lm, meId: meId),
                              const SizedBox(width: 4),
                            ],
                            if (lm != null)
                              Text(
                                chatListTime(lm.createdAt),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: secondary,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(child: preview),
                            if (chat.unread > 0) ...[
                              const SizedBox(width: 8),
                              _Badge(count: chat.unread),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Text shown under the chat title for its last message.
String previewText(Message? m) {
  if (m == null) return 'Нет сообщений';
  if (m.deleted) return 'Сообщение удалено';
  final caption = m.text.trim().replaceAll('\n', ' ');
  switch (m.kind) {
    case MessageKind.image:
      return caption.isEmpty ? 'Фотография' : 'Фотография, $caption';
    case MessageKind.video:
      return caption.isEmpty ? 'Видео' : 'Видео, $caption';
    case MessageKind.voice:
      final d = m.file?.durationMs ?? 0;
      return d > 0
          ? 'Голосовое сообщение, ${duration(d)}'
          : 'Голосовое сообщение';
    case MessageKind.file:
      return 'Документ: ${m.file?.name ?? 'файл'}';
    case MessageKind.call:
      return callMessageText(m);
    default:
      return caption;
  }
}

class _Ticks extends StatelessWidget {
  const _Ticks({required this.chat, required this.message, required this.meId});

  final Chat chat;
  final Message message;
  final int? meId;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    switch (message.state) {
      case SendState.pending:
        return Icon(
          Icons.schedule,
          size: 15,
          color: context.secondaryText,
          semanticLabel: 'Отправляется',
        );
      case SendState.failed:
        return const Icon(
          Icons.error_outline,
          size: 16,
          color: Fg.danger,
          semanticLabel: 'Не отправлено',
        );
      case SendState.sent:
        final selfChat = chat.memberIds.every((id) => id == meId);
        final read = selfChat || chat.othersReadId >= message.id;
        return Icon(
          read ? Icons.done_all : Icons.done,
          size: 17,
          color: color,
          semanticLabel: read ? 'Прочитано' : 'Доставлено',
        );
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        count > 999 ? '999+' : '$count',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
