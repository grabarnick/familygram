import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../auth/login_screen.dart' show RuPhoneFormatter, validateRuPhone;
import '../auth/name_screen.dart' show pickAndUploadAvatar, showError;
import '../format.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

/// Settings tab: profile, family phone list (admins), server, logout.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<AllowedPhone>? _phones;
  bool _phonesLoading = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    if (context.read<AppStore>().me?.isAdmin == true) _loadPhones();
  }

  Future<void> _loadPhones() async {
    final api = context.read<AppStore>().api;
    if (api == null) return;
    setState(() => _phonesLoading = true);
    try {
      final list = await api.listPhones();
      if (mounted) setState(() => _phones = list);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _phonesLoading = false);
    }
  }

  Future<void> _changePhoto() async {
    setState(() => _uploading = true);
    try {
      await pickAndUploadAvatar(context.read<AppStore>());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _editName() async {
    final store = context.read<AppStore>();
    final ctrl = TextEditingController(text: store.me?.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Имя'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Сохранить')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    try {
      await store.setDisplayName(name);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addPhone() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _AddPhoneDialog(),
    );
    if (result == null || !mounted) return;
    final api = context.read<AppStore>().api;
    try {
      await api?.addPhone(result.$1, displayName: result.$2.isEmpty ? null : result.$2);
      await _loadPhones();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _removePhone(AllowedPhone p) async {
    final ok = await _confirm(
      title: 'Удалить номер?',
      body: '${p.displayName.isEmpty ? prettyPhone(p.phone) : p.displayName} больше не сможет войти.',
      action: 'Удалить',
    );
    if (!ok || !mounted) return;
    try {
      await context.read<AppStore>().api?.removePhone(p.phone);
      await _loadPhones();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _logout() async {
    final ok = await _confirm(title: 'Выйти?', body: 'Чтобы войти снова, понадобится код из SMS.', action: 'Выйти');
    if (ok && mounted) await context.read<AppStore>().logout();
  }

  Future<bool> _confirm({required String title, required String body, required String action}) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(action),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final me = store.me;
    final secondary = context.secondaryText;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        children: [
          if (me != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Semantics(
                    button: true,
                    label: 'Сменить фото',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _uploading ? null : _changePhoto,
                      child: Stack(
                        children: [
                          Avatar(name: me.displayName, seed: me.id, fileId: me.avatarFileId, size: 72),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: Fg.accent,
                                shape: BoxShape.circle,
                                border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
                              ),
                              child: _uploading
                                  ? const Padding(
                                      padding: EdgeInsets.all(5),
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.photo_camera, size: 14, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(me.displayName,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(prettyPhone(me.phone), style: TextStyle(color: secondary, fontSize: 15)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Изменить имя',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _editName,
                  ),
                ],
              ),
            ),
          const Divider(),
          if (me?.isAdmin == true) ...[
            _SectionHeader('Семья'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Войти могут только эти номера.', style: TextStyle(color: secondary, fontSize: 13)),
            ),
            ListTile(
              minTileHeight: 52,
              leading: const Icon(Icons.person_add_alt_1_outlined, color: Fg.accent),
              title: const Text('Добавить номер', style: TextStyle(color: Fg.accent, fontWeight: FontWeight.w600)),
              onTap: _addPhone,
            ),
            if (_phonesLoading && _phones == null)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            for (final p in _phones ?? const <AllowedPhone>[])
              Dismissible(
                key: ValueKey(p.phone),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  await _removePhone(p);
                  return false; // list reloads itself
                },
                background: Container(
                  color: Theme.of(context).colorScheme.error,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(Icons.delete_outline, color: Colors.white),
                ),
                child: ListTile(
                  minTileHeight: 56,
                  title: Text(p.displayName.isEmpty ? prettyPhone(p.phone) : p.displayName),
                  subtitle: Text(
                    p.displayName.isEmpty
                        ? (p.registered ? 'Вошёл в приложение' : 'Ещё не входил')
                        : '${prettyPhone(p.phone)} · ${p.registered ? 'вошёл' : 'ещё не входил'}',
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Действия',
                    onSelected: (_) => _removePhone(p),
                    itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Удалить'))],
                  ),
                ),
              ),
            const Divider(),
          ],
          _SectionHeader('Сервер'),
          ListTile(
            minTileHeight: 52,
            leading: const Icon(Icons.dns_outlined),
            title: Text(store.serverUrl ?? '—', overflow: TextOverflow.ellipsis),
            subtitle: Text(_connectionText(store), style: TextStyle(color: secondary)),
          ),
          const Divider(),
          _SectionHeader('Звонки'),
          SwitchListTile(
            secondary: const Icon(Icons.shield_outlined),
            title: const Text('Звонки только через сервер'),
            subtitle: Text(
              store.callsEnabled
                  ? 'Включите, если звонки не соединяются'
                  : 'Звонки не настроены на этом сервере',
              style: TextStyle(color: secondary),
            ),
            value: store.forceRelay,
            onChanged: store.callsEnabled ? (v) => store.setForceRelay(v) : null,
          ),
          const Divider(),
          ListTile(
            minTileHeight: 52,
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text('Выйти', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: _logout,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _connectionText(AppStore store) {
    final s = store.connection.name;
    if (s == 'connected') return 'Подключено';
    if (s == 'connecting') return 'Подключение…';
    return 'Нет соединения';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                color: context.secondaryText, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      );
}

class _AddPhoneDialog extends StatefulWidget {
  const _AddPhoneDialog();

  @override
  State<_AddPhoneDialog> createState() => _AddPhoneDialogState();
}

class _AddPhoneDialogState extends State<_AddPhoneDialog> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final err = validateRuPhone(_phone.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, ('+7${RuPhoneFormatter.digitsOnly(_phone.text)}', _name.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Добавить в семью'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [RuPhoneFormatter()],
            decoration: InputDecoration(prefixText: '+7 ', hintText: '999 123-45-67', errorText: _error),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Имя (необязательно)'),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        TextButton(onPressed: _submit, child: const Text('Добавить')),
      ],
    );
  }
}
