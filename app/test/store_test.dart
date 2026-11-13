import 'dart:convert';

import 'package:familygram/data/api.dart';
import 'package:familygram/data/models.dart';
import 'package:familygram/data/realtime.dart';
import 'package:familygram/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const me = User(id: 1, phone: '+71', displayName: 'Я');
const mama = User(id: 2, phone: '+72', displayName: 'Мама');

Map<String, dynamic> msgJson(int id, int chatId, int sender, {String clientId = ''}) => {
      'id': id,
      'chat_id': chatId,
      'sender_id': sender,
      'client_id': clientId.isEmpty ? 'c$id' : clientId,
      'kind': 'text',
      'text': 'm$id',
      'file': null,
      'reply_to_id': null,
      'created_at': 1000 + id,
      'deleted': false,
    };

Chat chat(int id, {int lastId = 0}) => Chat(
      id: id,
      kind: 'direct',
      title: 'c$id',
      memberIds: const [1, 2],
      lastMessage: lastId == 0 ? null : Message.fromJson(msgJson(lastId, id, 2)),
      lastReadId: lastId,
    );

AppStore makeStore(http.Client client) {
  final store = AppStore(
    apiFactory: (url, token) => ApiClient(baseUrl: url, token: 't', client: client),
  );
  return store;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('message.new increments unread for a chat that is not open', () {
    final store = makeStore(MockClient((_) async => http.Response('{}', 200)));
    store.debugSeed(me: me, users: [mama], chats: [chat(1, lastId: 10), chat(2, lastId: 5)]);
    store.applyEvent(RealtimeEvent('message.new', msgJson(11, 2, 2)));
    expect(store.chatById(2)!.unread, 1);
    expect(store.chatById(1)!.unread, 0);
    // Chat 2 now has the newest activity.
    expect(store.chats.first.id, 2);
    expect(store.totalUnread, 1);
  });

  test('duplicate message.new does not double-count', () {
    final store = makeStore(MockClient((_) async => http.Response('{}', 200)));
    store.debugSeed(me: me, users: [mama], chats: [chat(2, lastId: 5)]);
    store.applyEvent(RealtimeEvent('message.new', msgJson(11, 2, 2)));
    store.applyEvent(RealtimeEvent('message.new', msgJson(11, 2, 2)));
    expect(store.chatById(2)!.unread, 1);
  });

  test('own messages do not count as unread', () {
    final store = makeStore(MockClient((_) async => http.Response('{}', 200)));
    store.debugSeed(me: me, chats: [chat(2, lastId: 5)]);
    store.applyEvent(RealtimeEvent('message.new', msgJson(12, 2, 1)));
    expect(store.chatById(2)!.unread, 0);
    expect(store.chatById(2)!.lastMessage!.id, 12);
  });

  test('optimistic send is replaced by server echo with same client_id', () async {
    String? sentClientId;
    final client = MockClient((req) async {
      if (req.url.path == '/api/chats/2/messages' && req.method == 'POST') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sentClientId = body['client_id'] as String;
        // Simulate the WS echo arriving before the HTTP response.
        return http.Response(jsonEncode(msgJson(20, 2, 1, clientId: sentClientId!)), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('[]', 200);
    });
    final store = makeStore(client);
    await store.requestCode('localhost:8080', '+71').catchError((_) => 0);
    store.debugSeed(me: me, chats: [chat(2, lastId: 5)]);
    final future = store.sendText(2, 'привет');
    final items = store.messagesOf(2).items;
    expect(items.single.state, SendState.pending);
    // WS echo arrives first.
    store.applyEvent(RealtimeEvent('message.new', msgJson(20, 2, 1, clientId: items.single.clientId)));
    await future;
    expect(store.messagesOf(2).items.length, 1);
    final m = store.messagesOf(2).items.single;
    expect(m.id, 20);
    expect(m.state, SendState.sent);
    expect(m.clientId, sentClientId);
    expect(store.chatById(2)!.lastMessage!.id, 20);
    expect(store.chatById(2)!.unread, 0);
  });

  test('failed send is marked failed and can be removed', () async {
    final client = MockClient((req) async =>
        http.Response(jsonEncode({'error': 'boom'}), 500));
    final store = makeStore(client);
    await store.requestCode('localhost', '+71').catchError((_) => 0);
    store.debugSeed(me: me, chats: [chat(2)]);
    await store.sendText(2, 'x');
    final m = store.messagesOf(2).items.single;
    expect(m.state, SendState.failed);
    await store.deleteMessage(m);
    expect(store.messagesOf(2).items, isEmpty);
  });

  test('chat.read from me clears unread, from others moves othersReadId', () {
    final store = makeStore(MockClient((_) async => http.Response('{}', 200)));
    store.debugSeed(me: me, chats: [chat(2, lastId: 5)]);
    store.applyEvent(RealtimeEvent('message.new', msgJson(6, 2, 2)));
    expect(store.chatById(2)!.unread, 1);
    store.applyEvent(RealtimeEvent('chat.read', {'chat_id': 2, 'user_id': 1, 'message_id': 6}));
    expect(store.chatById(2)!.unread, 0);
    store.applyEvent(RealtimeEvent('chat.read', {'chat_id': 2, 'user_id': 2, 'message_id': 6}));
    expect(store.chatById(2)!.othersReadId, 6);
  });

  test('message.deleted marks message and last message deleted', () {
    final store = makeStore(MockClient((_) async => http.Response('{}', 200)));
    store.debugSeed(me: me, chats: [chat(2, lastId: 5)]);
    store.applyEvent(RealtimeEvent('message.deleted', {'chat_id': 2, 'id': 5}));
    expect(store.chatById(2)!.lastMessage!.deleted, isTrue);
  });

  test('typing expires', () async {
    final store = makeStore(MockClient((_) async => http.Response('{}', 200)));
    store.debugSeed(me: me, chats: [chat(2)]);
    store.applyEvent(RealtimeEvent('typing', {'chat_id': 2, 'user_id': 2}));
    expect(store.typingIn(2), [2]);
    store.applyEvent(RealtimeEvent('typing', {'chat_id': 2, 'user_id': 1}));
    expect(store.typingIn(2), [2]);
  });

  test('verify stores session and flags new users', () async {
    final client = MockClient((req) async {
      switch (req.url.path) {
        case '/api/auth/request-code':
          return http.Response(jsonEncode({'retry_after': 60}), 200);
        case '/api/auth/verify':
          return http.Response(
              jsonEncode({
                'token': 'tok',
                'user': {'id': 1, 'phone': '+71', 'display_name': '+71', 'is_admin': false},
                'is_new': true,
              }),
              200);
        case '/api/users':
        case '/api/chats':
          return http.Response('[]', 200);
      }
      return http.Response('{}', 404);
    });
    final store = AppStore(
      apiFactory: (url, token) => ApiClient(baseUrl: url, token: token, client: client),
      realtimeFactory: (api) => Realtime(() => api.wsUri,
          connector: (_) => throw UnsupportedError('no ws in tests')),
    );
    await store.init();
    expect(await store.requestCode('family.example.ru', '+71'), 60);
    expect(store.serverUrl, 'https://family.example.ru');
    await store.verify('123456');
    expect(store.isSignedIn, isTrue);
    expect(store.needsName, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), 'tok');
    store.dispose();
  });

  test('429 carries retry_after', () async {
    final client = MockClient((req) async =>
        http.Response.bytes(utf8.encode(jsonEncode({'error': 'Подождите', 'retry_after': 42})), 429));
    final api = ApiClient(baseUrl: 'x', client: client);
    try {
      await api.requestCode('+71');
      fail('should throw');
    } on ApiException catch (e) {
      expect(e.status, 429);
      expect(e.retryAfter, 42);
      expect(e.message, 'Подождите');
      expect(e.codeSent, isFalse);
    }
  });

  AppStore storeAnswering(http.Response Function() requestCode) => AppStore(
        apiFactory: (url, token) => ApiClient(
          baseUrl: url,
          token: token,
          client: MockClient((req) async => requestCode()),
        ),
        realtimeFactory: (api) => Realtime(() => api.wsUri,
            connector: (_) => throw UnsupportedError('no ws in tests')),
      );

  test('code already sent: goes to code entry with the remaining countdown', () async {
    // User went back from the code screen and tapped "Get code" again within 60s.
    final store = storeAnswering(() => http.Response.bytes(
        utf8.encode(jsonEncode({'error': 'Код уже отправлен, подождите', 'retry_after': 37, 'code_sent': true})),
        429));
    await store.init();
    expect(await store.requestCode('family.example.ru', '+79990000002'), 37);
    expect(store.pendingPhone, '+79990000002');
    expect(store.codeResendAfter, 37);
    store.dispose();
  });

  group('ringing call missed while the realtime socket was down', () {
    // Mom (id 2) is signed in on the phone; Dad (id 1) calls while iOS has the
    // app suspended, so the "call ringing" event never arrives. The call list
    // fetched on reconnect/resume must still raise the incoming screen.
    Future<AppStore> signedInMom(List<Map<String, dynamic>> calls) async {
      final client = MockClient((req) async {
        switch (req.url.path) {
          case '/api/auth/request-code':
            return http.Response(jsonEncode({'retry_after': 60}), 200);
          case '/api/auth/verify':
            return http.Response.bytes(
                utf8.encode(jsonEncode({
                  'token': 'tok',
                  'user': {'id': 2, 'phone': '+79990000002', 'display_name': 'Мама', 'is_admin': false},
                  'is_new': false,
                })),
                200);
          case '/api/info':
            return http.Response(jsonEncode({'name': 'F', 'auth': 'sms', 'calls': true}), 200);
          case '/api/calls':
            return http.Response(jsonEncode(calls), 200);
          case '/api/users':
          case '/api/chats':
            return http.Response('[]', 200);
        }
        return http.Response('{}', 404);
      });
      final store = AppStore(
        apiFactory: (url, token) => ApiClient(baseUrl: url, token: token, client: client),
        realtimeFactory: (api) => Realtime(() => api.wsUri,
            connector: (_) => throw UnsupportedError('no ws in tests')),
      );
      await store.init();
      await store.requestCode('family.example.ru', '+79990000002');
      await store.verify('123456');
      return store;
    }

    Map<String, dynamic> call(int id, {String state = 'ringing', int initiator = 1, List<int> participants = const [1]}) => {
          'id': id,
          'chat_id': 1,
          'initiator_id': initiator,
          'video': true,
          'state': state,
          'participant_ids': participants,
          'created_at': 1794560000000,
        };

    test('a ringing call from someone else raises the incoming screen', () async {
      final store = await signedInMom([call(13)]);
      await store.refreshCalls();
      expect(store.incomingCall?.id, 13);
      store.dispose();
    });

    test('my own, answered or finished calls do not ring', () async {
      final store = await signedInMom([
        call(20, initiator: 2, participants: [2]), // my outgoing call
        call(21, participants: [1, 2]), // I'm already in it
        call(22, state: 'missed'),
        call(23, state: 'active', participants: [1, 2]),
      ]);
      await store.refreshCalls();
      expect(store.incomingCall, isNull);
      store.dispose();
    });

    test('a declined call does not come back on the next refresh', () async {
      final store = await signedInMom([call(13)]);
      await store.refreshCalls();
      expect(store.incomingCall?.id, 13);
      await store.declineIncoming();
      await store.refreshCalls(); // server may still report it ringing briefly
      expect(store.incomingCall, isNull);
      store.dispose();
    });
  });

  test('generic rate limit still fails and stays on the phone screen', () async {
    final store = storeAnswering(() => http.Response.bytes(
        utf8.encode(jsonEncode({'error': 'Слишком много запросов, попробуйте позже', 'retry_after': 3600})),
        429));
    await store.init();
    await expectLater(
      store.requestCode('family.example.ru', '+79990000002'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 429)),
    );
    expect(store.pendingPhone, isNull);
    store.dispose();
  });
}
