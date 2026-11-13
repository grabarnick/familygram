import 'dart:convert';

import 'package:familygram/data/api.dart';
import 'package:familygram/data/realtime.dart';
import 'package:familygram/data/store.dart';
import 'package:familygram/ui/auth/code_screen.dart';
import 'package:familygram/ui/auth/login_screen.dart';
import 'package:familygram/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeServer {
  final requests = <http.Request>[];

  late final client = MockClient((req) async {
    requests.add(req);
    switch (req.url.path) {
      case '/api/auth/request-code':
        return http.Response(jsonEncode({'retry_after': 60}), 200);
      case '/api/auth/verify':
        return http.Response(
            jsonEncode({
              'token': 'tok',
              'user': {'id': 1, 'phone': '+79991234567', 'display_name': 'Я', 'is_admin': false},
              'is_new': false,
            }),
            200);
      case '/api/users':
      case '/api/chats':
        return http.Response('[]', 200);
    }
    return http.Response('{}', 404);
  });

  AppStore store() => AppStore(
        apiFactory: (url, token) => ApiClient(baseUrl: url, token: token, client: client),
        realtimeFactory: (api) =>
            Realtime(() => api.wsUri, connector: (_) => throw UnsupportedError('no ws in tests')),
      );

  Iterable<Map<String, dynamic>> bodies(String path) => requests
      .where((r) => r.url.path == path)
      .map((r) => jsonDecode(r.body) as Map<String, dynamic>);
}

Widget host(AppStore store, Widget child) => ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: child),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('validateRuPhone', () {
    expect(validateRuPhone(''), isNotNull);
    expect(validateRuPhone('999 123'), isNotNull);
    expect(validateRuPhone('999 123-45-67'), isNull);
  });

  test('RuPhoneFormatter formats and strips country code on paste', () {
    final f = RuPhoneFormatter();
    String fmt(String s) =>
        f.formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: s)).text;
    expect(fmt('9991234567'), '999 123-45-67');
    expect(fmt('+7 (999) 123-45-67'), '999 123-45-67');
    expect(fmt('89991234567'), '999 123-45-67');
    expect(fmt('99912'), '999 12');
  });

  testWidgets('LoginScreen rejects a short number and sends a valid one', (tester) async {
    final server = FakeServer();
    final store = server.store();
    await tester.pumpWidget(host(store, const LoginScreen()));
    await tester.enterText(find.byKey(const Key('server')), 'family.example.ru');

    await tester.enterText(find.byKey(const Key('phone')), '999123');
    await tester.tap(find.byKey(const Key('get_code')));
    await tester.pump();
    expect(find.byKey(const Key('login_error')), findsOneWidget);
    expect(server.requests, isEmpty);

    await tester.enterText(find.byKey(const Key('phone')), '9991234567');
    await tester.tap(find.byKey(const Key('get_code')));
    await tester.pumpAndSettle();
    expect(server.bodies('/api/auth/request-code').single['phone'], '+79991234567');
    expect(store.pendingPhone, '+79991234567');
    expect(store.serverUrl, 'https://family.example.ru');
  });

  testWidgets('CodeScreen auto-submits after 6 digits', (tester) async {
    final server = FakeServer();
    final store = server.store();
    await tester.runAsync(() => store.requestCode('family.example.ru', '+79991234567'));
    await tester.pumpWidget(host(store, const CodeScreen()));
    expect(find.text('Отправили SMS на +7 999 123-45-67 '), findsOneWidget);

    await tester.enterText(find.byKey(const Key('code_input')), '12345');
    await tester.pump();
    expect(server.bodies('/api/auth/verify'), isEmpty);

    await tester.enterText(find.byKey(const Key('code_input')), '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(server.bodies('/api/auth/verify').single['code'], '123456');

    // Dispose the screen (cancels its countdown) and the store (stops realtime).
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
}
