import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';

import '../../data/api.dart';
import '../../data/store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

/// Lets the user pick a photo and uploads it as their avatar.
/// Returns false when nothing was picked; throws [ApiException] on upload errors.
Future<bool> pickAndUploadAvatar(AppStore store) async {
  final api = store.api;
  if (api == null) return false;
  final picked = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1024,
    maxHeight: 1024,
    imageQuality: 85,
  );
  if (picked == null) return false;
  final bytes = await picked.readAsBytes();
  final mime = picked.mimeType ?? lookupMimeType(picked.name, headerBytes: bytes) ?? 'image/jpeg';
  final file = await api.uploadFile(bytes, filename: picked.name, mime: mime);
  await store.updateAvatar(file.id);
  return true;
}

void showError(BuildContext context, Object e) {
  final msg = e is ApiException ? e.message : 'Что-то пошло не так';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// First sign-in: "Как вас зовут?".
class NameScreen extends StatefulWidget {
  const NameScreen({super.key});

  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> {
  late final TextEditingController _name;
  bool _busy = false;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final me = context.read<AppStore>().me;
    final current = me?.displayName ?? '';
    // The server may default the name to the phone number — don't prefill that.
    _name = TextEditingController(text: current.startsWith('+') ? '' : current);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    setState(() => _uploading = true);
    try {
      await pickAndUploadAvatar(context.read<AppStore>());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Введите имя');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppStore>().setDisplayName(name);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final me = store.me;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Semantics(
                      button: true,
                      label: 'Выбрать фото',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _uploading ? null : _pickPhoto,
                        child: Stack(
                          children: [
                            me?.avatarFileId != null
                                ? Avatar(
                                    name: _name.text.isEmpty ? '?' : _name.text,
                                    seed: me?.id ?? 0,
                                    fileId: me?.avatarFileId,
                                    size: 104)
                                : Container(
                                    width: 104,
                                    height: 104,
                                    decoration: const BoxDecoration(color: Fg.accentTint, shape: BoxShape.circle),
                                    child: _uploading
                                        ? const Padding(
                                            padding: EdgeInsets.all(36),
                                            child: CircularProgressIndicator(strokeWidth: 2.5))
                                        : const Icon(Icons.add_a_photo_outlined, color: Fg.accent, size: 36),
                                  ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Как вас зовут?',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text('Так вас увидят родные. Фото можно добавить позже.',
                      textAlign: TextAlign.center, style: TextStyle(color: context.secondaryText, fontSize: 15)),
                  const SizedBox(height: 28),
                  TextField(
                    key: const Key('name'),
                    controller: _name,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.name],
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _submit(),
                    style: const TextStyle(fontSize: 18),
                    decoration: InputDecoration(hintText: 'Имя', errorText: _error),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Продолжить'),
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
