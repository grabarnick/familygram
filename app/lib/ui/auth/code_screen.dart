import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/api.dart';
import '../../data/store.dart';
import '../format.dart';
import '../theme.dart';

/// Enter the 6-digit SMS code.
class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key, this.resendAfter = 60});

  /// Seconds before "send again" becomes available.
  final int resendAfter;

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> with SingleTickerProviderStateMixin {
  static const length = 6;
  final _code = TextEditingController();
  final _focus = FocusNode();
  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
  Timer? _timer;
  late int _left = widget.resendAfter;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left = math.max(0, _left - 1));
      if (_left == 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => _error = null);
    if (v.length == length) _verify();
  }

  Future<void> _verify() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await context.read<AppStore>().verify(_code.text);
    } on ApiException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('Не удалось связаться с сервером');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _error = msg;
      _code.clear();
    });
    _shake.forward(from: 0);
    _focus.requestFocus();
  }

  Future<void> _resend() async {
    final store = context.read<AppStore>();
    final phone = store.pendingPhone;
    final server = store.serverUrl;
    if (phone == null || server == null) return;
    try {
      final wait = await store.requestCode(server, phone);
      if (!mounted) return;
      setState(() {
        _left = wait > 0 ? wait : widget.resendAfter;
        _error = null;
      });
      _startTimer();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        if (e.retryAfter != null) _left = e.retryAfter!;
      });
      if (_left > 0) _startTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final theme = Theme.of(context);
    final secondary = context.secondaryText;
    final phone = store.pendingPhone ?? '';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Назад',
          icon: const Icon(Icons.arrow_back),
          onPressed: store.cancelCode,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Введите код',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Отправили SMS на ${prettyPhone(phone)} ',
                          style: TextStyle(color: secondary, fontSize: 15)),
                      TextButton(
                        onPressed: store.cancelCode,
                        style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                        child: const Text('Изменить'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  AnimatedBuilder(
                    animation: _shake,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(math.sin(_shake.value * math.pi * 6) * 10 * (1 - _shake.value), 0),
                      child: child,
                    ),
                    child: _cells(theme),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Text(_error!,
                        key: const Key('code_error'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error, fontSize: 14)),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Center(
                          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
                    ),
                  const SizedBox(height: 24),
                  Center(
                    child: _left > 0
                        ? Text('Отправить ещё раз через ${duration(_left * 1000)}',
                            style: TextStyle(color: secondary, fontSize: 14))
                        : TextButton(
                            onPressed: _resend,
                            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                            child: const Text('Отправить код ещё раз'),
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

  Widget _cells(ThemeData theme) {
    final text = _code.text;
    final errorColor = theme.colorScheme.error;
    return GestureDetector(
      onTap: () => _focus.requestFocus(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(length, (i) {
              final filled = i < text.length;
              final active = i == text.length && _focus.hasFocus;
              return Container(
                width: 46,
                height: 56,
                margin: EdgeInsets.only(left: i == 0 ? 0 : (i == 3 ? 14 : 8)),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.inputDecorationTheme.fillColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    width: 2,
                    color: _error != null
                        ? errorColor
                        : active
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                  ),
                ),
                child: Text(filled ? text[i] : '',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
              );
            }),
          ),
          // One real input under the cells: handles typing, paste and SMS autofill.
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                key: const Key('code_input'),
                controller: _code,
                focusNode: _focus,
                autofocus: true,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                maxLength: length,
                showCursor: false,
                enableInteractiveSelection: false,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(counterText: '', filled: false, border: InputBorder.none),
                onChanged: _onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
