import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/api.dart';
import '../../data/store.dart';
import '../theme.dart';

/// Formats the 10 national digits after +7 as "999 123-45-67".
class RuPhoneFormatter extends TextInputFormatter {
  static String digitsOnly(String s) => s.replaceAll(RegExp(r'\D'), '');

  static String format(String digits) {
    final d = digits.length > 10 ? digits.substring(0, 10) : digits;
    final b = StringBuffer();
    for (var i = 0; i < d.length; i++) {
      if (i == 3) b.write(' ');
      if (i == 6 || i == 8) b.write('-');
      b.write(d[i]);
    }
    return b.toString();
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var digits = digitsOnly(newValue.text);
    // Pasted full numbers: "+7 999…", "8 999…", "7999…".
    if (digits.length == 11 && (digits.startsWith('7') || digits.startsWith('8'))) {
      digits = digits.substring(1);
    }
    final text = format(digits);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Returns an error text for the national part of a Russian number, or null.
String? validateRuPhone(String input) {
  final d = RuPhoneFormatter.digitsOnly(input);
  if (d.isEmpty) return 'Введите номер телефона';
  if (d.length != 10) return 'В номере должно быть 10 цифр после +7';
  return null;
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _server = TextEditingController();
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _server.text = store.serverUrl ?? (kIsWeb && Uri.base.hasAuthority && Uri.base.scheme.startsWith('http')
        ? Uri.base.origin
        : '');
  }

  @override
  void dispose() {
    _phone.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phoneErr = validateRuPhone(_phone.text);
    if (_server.text.trim().isEmpty) {
      setState(() => _error = 'Укажите адрес сервера');
      return;
    }
    if (phoneErr != null) {
      setState(() => _error = phoneErr);
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final phone = '+7${RuPhoneFormatter.digitsOnly(_phone.text)}';
      await context.read<AppStore>().requestCode(_server.text.trim(), phone);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось связаться с сервером');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = context.secondaryText;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: LogoMark()),
                    const SizedBox(height: 20),
                    Text(
                      'Familygram',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Семейный мессенджер на вашем сервере',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: secondary, fontSize: 15),
                    ),
                    const SizedBox(height: 40),
                    Text('Номер телефона',
                        style: TextStyle(color: secondary, fontSize: 13, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 6),
                    TextField(
                      key: const Key('phone'),
                      controller: _phone,
                      autofocus: true,
                      keyboardType: TextInputType.phone,
                      autofillHints: const [AutofillHints.telephoneNumberNational],
                      inputFormatters: [RuPhoneFormatter()],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500, letterSpacing: 0.5),
                      decoration: InputDecoration(
                        hintText: '999 123-45-67',
                        prefixIcon: Padding(
                          padding: const EdgeInsets.only(left: 14, right: 8),
                          child: Text('+7',
                              style: TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface)),
                        ),
                        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(_error!,
                          key: const Key('login_error'),
                          style: TextStyle(color: theme.colorScheme.error, fontSize: 14)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('get_code'),
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : const Text('Получить код'),
                    ),
                    const SizedBox(height: 12),
                    Text('Мы отправим SMS с кодом',
                        textAlign: TextAlign.center, style: TextStyle(color: secondary, fontSize: 14)),
                    const SizedBox(height: 48),
                    Text('Адрес сервера', style: TextStyle(color: secondary, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextField(
                      key: const Key('server'),
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      style: TextStyle(fontSize: 14, color: secondary),
                      decoration: const InputDecoration(
                        hintText: 'family.example.ru',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Brand mark: rounded square with a speech bubble and a heart-ish dot.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 72});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Fg.accent, borderRadius: BorderRadius.circular(size * 0.28)),
      child: Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: size * 0.5),
    );
  }
}
