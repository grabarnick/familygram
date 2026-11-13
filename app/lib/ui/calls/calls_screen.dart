import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../call/call_controller.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

/// Calls tab: history of calls with call-back on tap.
class CallsScreen extends StatelessWidget {
  const CallsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Звонки',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      ),
      body: !store.callsEnabled
          ? const _Empty(
              title: 'Звонки не настроены',
              text: 'Администратору сервера нужно включить LiveKit '
                  '(см. README, раздел «Звонки»).',
            )
          : RefreshIndicator(
              onRefresh: () => store.refreshCalls().catchError((_) {}),
              child: store.callHistory.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 120),
                      _Empty(
                        title: 'Звонков пока не было',
                        text: 'Позвоните родным из любого чата — кнопки вверху справа.',
                      ),
                    ])
                  : ListView.separated(
                      itemCount: store.callHistory.length,
                      separatorBuilder: (_, _) => const Divider(indent: 82),
                      itemBuilder: (context, i) => CallRow(call: store.callHistory[i]),
                    ),
            ),
    );
  }
}

/// One row of the call history.
class CallRow extends StatelessWidget {
  const CallRow({super.key, required this.call});

  final Call call;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final me = store.me?.id;
    final chat = store.chatById(call.chatId);
    final outgoing = call.initiatorId == me;
    final missed = !outgoing && (call.isMissed || call.state == CallState.declined);
    final otherId = chat == null || chat.isGroup
        ? null
        : chat.memberIds.firstWhere((id) => id != me, orElse: () => chat.id);
    final title = chat?.title ?? store.userName(call.initiatorId);
    final live = call.isLive;

    final String status;
    if (live) {
      status = 'Идёт сейчас';
    } else if (missed) {
      status = call.state == CallState.declined ? 'Отклонённый' : 'Пропущенный';
    } else if (outgoing) {
      status = call.durationMs > 0
          ? 'Исходящий · ${duration(call.durationMs)}'
          : 'Исходящий · без ответа';
    } else {
      status = 'Входящий · ${duration(call.durationMs)}';
    }

    final dangerColor = Theme.of(context).colorScheme.error;
    final statusColor = missed ? dangerColor : context.secondaryText;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Avatar(
        name: title,
        seed: otherId ?? call.chatId,
        fileId: otherId != null ? store.users[otherId]?.avatarFileId : chat?.avatarFileId,
        size: 50,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: missed ? dangerColor : null,
        ),
      ),
      subtitle: Row(
        children: [
          Icon(
            missed
                ? Icons.call_missed
                : outgoing
                    ? Icons.call_made
                    : Icons.call_received,
            key: ValueKey(missed ? 'missed' : outgoing ? 'out' : 'in'),
            size: 16,
            color: statusColor,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: statusColor)),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(chatListTime(call.createdAt),
              style: TextStyle(color: context.secondaryText, fontSize: 13)),
          const SizedBox(width: 4),
          IconButton(
            tooltip: live
                ? 'Присоединиться'
                : call.video
                    ? 'Видеозвонок'
                    : 'Аудиозвонок',
            icon: Icon(call.video ? Icons.videocam_outlined : Icons.call_outlined,
                color: Theme.of(context).colorScheme.primary),
            onPressed: () => live
                ? CallController.join(context, call)
                : CallController.start(context, call.chatId, video: call.video),
          ),
        ],
      ),
      onTap: () => live
          ? CallController.join(context, call)
          : CallController.start(context, call.chatId, video: call.video),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration:
                  const BoxDecoration(color: Fg.accentTint, shape: BoxShape.circle),
              child: const Icon(Icons.call_outlined, color: Fg.accent, size: 40),
            ),
            const SizedBox(height: 20),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.secondaryText, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}
