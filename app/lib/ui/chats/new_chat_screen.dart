import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/api.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

String _errorText(Object e) => e is ApiException ? e.message : 'Не удалось: $e';

List<User> _family(AppStore store) {
  final list = store.users.values.where((u) => u.id != store.me?.id).toList()
    ..sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
  return list;
}

/// Pick someone to chat with, or create a group. Pops with the chat id.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  bool _busy = false;

  Future<void> _open(int userId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final chat = await context.read<AppStore>().openDirect(userId);
      if (mounted) Navigator.of(context).pop(chat.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_errorText(e))));
    }
  }

  Future<void> _newGroup() async {
    final id = await Navigator.of(context)
        .push<int>(MaterialPageRoute(builder: (_) => const NewGroupScreen()));
    if (id != null && mounted) Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final me = store.me;
    final family = _family(store);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Новый чат'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        children: [
          ListTile(
            minTileHeight: 60,
            leading: CircleAvatar(
              radius: 22,
              backgroundColor: context.isDark
                  ? scheme.primary.withValues(alpha: 0.18)
                  : Fg.accentTint,
              foregroundColor: scheme.primary,
              child: const Icon(Icons.group_add_outlined),
            ),
            title: const Text(
              'Новая группа',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            onTap: _busy ? null : _newGroup,
          ),
          if (me != null)
            ListTile(
              minTileHeight: 60,
              leading: CircleAvatar(
                radius: 22,
                backgroundColor: Fg.avatarColors[5],
                foregroundColor: Colors.white,
                child: const Icon(Icons.bookmark_outline),
              ),
              title: const Text(
                'Избранное',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Заметки и файлы для себя'),
              onTap: _busy ? null : () => _open(me.id),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text(
              'СЕМЬЯ',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: context.secondaryText,
              ),
            ),
          ),
          if (family.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Здесь пока никого нет. Администратор может добавить номера родных в настройках.',
                style: TextStyle(color: context.secondaryText),
              ),
            ),
          for (final u in family)
            ListTile(
              minTileHeight: 64,
              leading: Avatar(
                name: u.displayName,
                seed: u.id,
                fileId: u.avatarFileId,
                size: 44,
              ),
              title: Text(
                u.displayName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(prettyPhone(u.phone)),
              onTap: _busy ? null : () => _open(u.id),
            ),
        ],
      ),
    );
  }
}

/// Group creation: title + members. Pops with the new chat id.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _title = TextEditingController();
  final Set<int> _selected = {};
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _canCreate =>
      !_busy && _title.text.trim().isNotEmpty && _selected.isNotEmpty;

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final chat = await context.read<AppStore>().createGroup(
        _title.text.trim(),
        _selected.toList(),
      );
      if (mounted) Navigator.of(context).pop(chat.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final family = _family(context.watch<AppStore>());
    return Scaffold(
      appBar: AppBar(title: const Text('Новая группа')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Название группы'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Text(
                  'УЧАСТНИКИ',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: context.secondaryText,
                  ),
                ),
                const Spacer(),
                Text(
                  'Выбрано: ${_selected.length}',
                  style: TextStyle(fontSize: 13, color: context.secondaryText),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final u in family)
                  CheckboxListTile(
                    value: _selected.contains(u.id),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            if (v == true) {
                              _selected.add(u.id);
                            } else {
                              _selected.remove(u.id);
                            }
                          }),
                    secondary: Avatar(
                      name: u.displayName,
                      seed: u.id,
                      fileId: u.avatarFileId,
                      size: 44,
                    ),
                    title: Text(
                      u.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(prettyPhone(u.phone)),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: _canCreate ? _create : null,
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Text('Создать группу'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
