import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:familygram/data/api.dart';
import 'package:familygram/data/callkit.dart';
import 'package:familygram/data/models.dart';
import 'package:familygram/data/push.dart';
import 'package:familygram/data/realtime.dart';
import 'package:familygram/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  group('push notifications', () {
    late List<Map<String, dynamic>> devices;
    late List<String> posted;

    Future<AppStore> signedIn(FakePush push, {FakeCallKit? callKit}) async {
      devices = [];
      posted = [];
      final client = MockClient((req) async {
        if (req.method == 'POST') posted.add(req.url.path);
        if (req.url.path.startsWith('/api/calls/')) return http.Response('{}', 200);
        switch (req.url.path) {
          case '/api/info':
            return http.Response(jsonEncode({'name': 'F', 'auth': 'sms', 'calls': true}), 200);
          case '/api/calls':
            return http.Response('[]', 200);
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
          case '/api/devices':
            devices.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(jsonEncode({'ok': true, 'push': true}), 200);
          case '/api/chats':
            return http.Response.bytes(
                utf8.encode(jsonEncode([
                  {'id': 1, 'kind': 'direct', 'title': 'Папа', 'member_ids': [1, 2], 'unread': 2},
                  {'id': 3, 'kind': 'group', 'title': 'Семья', 'member_ids': [1, 2, 3], 'unread': 1},
                ])),
                200);
          case '/api/users':
            return http.Response('[]', 200);
          case '/api/auth/logout':
            return http.Response('{"ok":true}', 200);
        }
        return http.Response('{}', 404);
      });
      final store = AppStore(
        apiFactory: (url, token) => ApiClient(baseUrl: url, token: token, client: client),
        realtimeFactory: (api) => Realtime(() => api.wsUri,
            connector: (_) => throw UnsupportedError('no ws in tests')),
        push: push,
        callKit: callKit,
      );
      await store.init();
      await store.requestCode('family.example.ru', '+79990000002');
      await store.verify('123456');
      await pumpEventQueue();
      return store;
    }

    test('after sign-in the phone is registered with the server', () async {
      final store = await signedIn(FakePush(registration: const PushRegistration(
          platform: 'ios', token: 'abcd1234', sandbox: true)));
      expect(devices, [
        {'platform': 'ios', 'token': 'abcd1234', 'sandbox': true, 'kind': 'alert'}
      ]);
      store.dispose();
    });

    // ---- incoming calls on the system call screen (CallKit) ----

    const sandboxPush = PushRegistration(platform: 'ios', token: 'abcd1234', sandbox: true);

    Map<String, dynamic> ringing(int id) => {
          'id': id,
          'chat_id': 1,
          'initiator_id': 1,
          'video': false,
          'state': 'ringing',
          'participant_ids': [1],
          'created_at': 1794560000000,
        };

    test('the VoIP token is registered and CallKit rings instead of the app', () async {
      final ck = FakeCallKit(token: 'f00d');
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);
      expect(devices, contains(equals({'platform': 'ios', 'token': 'f00d', 'sandbox': true, 'kind': 'voip'})));
      expect(store.callKitRings, isTrue);
      store.applyEvent(RealtimeEvent(RealtimeEvent.callRing, ringing(7)));
      expect(store.incomingCall, isNull, reason: 'no second ring in the app');
      store.dispose();
    });

    test('without a VoIP token the app shows its own incoming screen', () async {
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: FakeCallKit(token: null));
      expect(store.callKitRings, isFalse);
      store.applyEvent(RealtimeEvent(RealtimeEvent.callRing, ringing(7)));
      expect(store.incomingCall?.id, 7);
      store.dispose();
    });

    test('a VoIP token issued later is registered then', () async {
      final ck = FakeCallKit(token: null);
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);
      ck.token = 'beef';
      ck.emit(const CallKitAction(CallKitActionKind.tokenUpdated));
      await pumpEventQueue();
      expect(devices.where((d) => d['kind'] == 'voip').single['token'], 'beef');
      expect(store.callKitRings, isTrue);
      store.dispose();
    });

    test('accept / decline / hang up on the system screen', () async {
      final ck = FakeCallKit(token: 'f00d');
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);

      ck.emit(const CallKitAction(CallKitActionKind.accept, 7));
      await pumpEventQueue();
      expect(store.takeCallKitAcceptRequest(), 7);

      ck.emit(const CallKitAction(CallKitActionKind.decline, 8));
      await pumpEventQueue();
      expect(posted, contains('/api/calls/8/decline'));

      // Hanging up on the lock screen asks the open call screen to hang up.
      final c = (await store.findLiveCall(9)) ?? Call.fromJson({...ringing(9), 'state': 'active'});
      store.debugSetActiveCall(c);
      ck.emit(const CallKitAction(CallKitActionKind.ended, 9));
      await pumpEventQueue();
      expect(store.callKitEndRequest, 9);
      await store.leaveCall();
      expect(store.callKitEndRequest, isNull);
      expect(ck.ended, contains(9), reason: 'leaving takes the call off the system screen');
      store.dispose();
    });

    test('accept goes straight to the UI handler, without waiting for a redraw', () async {
      final ck = FakeCallKit(token: 'f00d');
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);
      final joined = <int>[];
      store.onCallKitAccept = joined.add;
      ck.emit(const CallKitAction(CallKitActionKind.accept, 7));
      await pumpEventQueue();
      expect(joined, [7]);
      expect(store.callKitAcceptRequest, isNull);
      store.dispose();
    });

    test('our own answer does not close the system screen (event before reply)', () async {
      final ck = FakeCallKit(token: 'f00d');
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);
      store.onCallKitAccept = (_) {}; // the UI is now joining
      ck.emit(const CallKitAction(CallKitActionKind.accept, 7));
      await pumpEventQueue();
      // The server's "active" event arrives before the reply to our join.
      store.applyEvent(RealtimeEvent(RealtimeEvent.callUpdated,
          {...ringing(7), 'state': 'active', 'participant_ids': [1, 2]}));
      expect(ck.ended, isEmpty);
      store.dispose();
    });

    test('a 1:1 call answered on another phone stops ringing here', () async {
      final ck = FakeCallKit(token: 'f00d');
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);
      store.applyEvent(RealtimeEvent(RealtimeEvent.callRing, ringing(7)));
      store.applyEvent(RealtimeEvent(RealtimeEvent.callUpdated,
          {...ringing(7), 'state': 'active', 'participant_ids': [1, 2]}));
      expect(ck.ended, [7]);
      store.dispose();
    });

    test('a call that ends while ringing is taken off the system screen', () async {
      final ck = FakeCallKit(token: 'f00d');
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);
      store.applyEvent(RealtimeEvent(RealtimeEvent.callRing, ringing(7)));
      store.applyEvent(RealtimeEvent(RealtimeEvent.callEnded, {...ringing(7), 'state': 'missed'}));
      expect(ck.ended, [7]);
      store.dispose();
    });

    test('an accept that launched the app is picked up after sign-in', () async {
      final ck = FakeCallKit(token: 'f00d')..accepted = [12];
      final store = await signedIn(FakePush(registration: sandboxPush), callKit: ck);
      expect(store.callKitAcceptRequest, 12);
      store.dispose();
    });

    test('CallKit UUID matches the server and round-trips', () {
      expect(callKitUuid(255), '00000000-0000-4000-8000-0000000000ff');
      expect(callIdFromCallKitUuid(callKitUuid(123456)), 123456);
      expect(callIdFromCallKitUuid('E621E1F8-C36C-495A-93FC-0C247A3E6E5F'), isNull);
    });

    test('declined notifications: nothing is registered', () async {
      final store = await signedIn(FakePush(registration: null));
      expect(devices, isEmpty);
      store.dispose();
    });

    test('tapping a notification asks to open its chat', () async {
      final push = FakePush(registration: null);
      final store = await signedIn(push);
      expect(store.openChatRequest, isNull);
      push.tap(3);
      await pumpEventQueue();
      expect(store.takeOpenChatRequest(), 3);
      expect(store.openChatRequest, isNull);
      store.dispose();
    });

    test('the tap that launched the app is picked up after sign-in', () async {
      final push = FakePush(registration: null)..tapped = 1;
      final store = await signedIn(push);
      expect(store.openChatRequest, 1);
      store.dispose();
    });

    test('the icon badge follows unread and clears on logout', () async {
      final push = FakePush(registration: null);
      final store = await signedIn(push);
      expect(push.badges.last, 3);
      await store.logout();
      expect(push.badges.last, 0);
      store.dispose();
    });
  });

  group('opening without a connection', () {
    const mom = {'id': 2, 'phone': '+79990000002', 'display_name': 'Мама', 'is_admin': false};

    // A saved session, as after a previous successful sign-in.
    void savedSession({bool withProfile = true}) => SharedPreferences.setMockInitialValues({
          'server_url': 'http://mac.local:8080',
          'token': 'tok',
          if (withProfile) 'me': jsonEncode(mom),
        });

    test('opens signed in with the saved profile and catches up when online', () async {
      savedSession();
      var online = false;
      final client = MockClient((req) async {
        if (!online) throw const SocketException('no route to host');
        switch (req.url.path) {
          case '/api/me':
            return http.Response.bytes(utf8.encode(jsonEncode({...mom, 'display_name': 'Мама Оля'})), 200);
          case '/api/chats':
            return http.Response.bytes(
                utf8.encode(jsonEncode([
                  {'id': 1, 'kind': 'direct', 'title': 'Папа', 'member_ids': [1, 2], 'unread': 1}
                ])),
                200);
          case '/api/users':
          case '/api/calls':
            return http.Response('[]', 200);
          case '/api/info':
            return http.Response(jsonEncode({'name': 'F', 'auth': 'sms', 'calls': true}), 200);
        }
        return http.Response('{}', 404);
      });
      final channel = FakeChannel();
      final store = AppStore(
        apiFactory: (url, token) => ApiClient(baseUrl: url, token: token, client: client),
        realtimeFactory: (api) => Realtime(() => api.wsUri, connector: (_) => channel),
      );
      await store.init();
      expect(store.isSignedIn, isTrue, reason: 'not the login screen');
      expect(store.me?.displayName, 'Мама');
      expect(store.chats, isEmpty);

      online = true;
      channel.connect();
      await pumpEventQueue();
      expect(store.me?.displayName, 'Мама Оля', reason: 'profile refreshed');
      expect(store.chats.single.title, 'Папа', reason: 'chats loaded on reconnect');
      expect(store.callsEnabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('me')!)['display_name'], 'Мама Оля');
      store.dispose();
    });

    test('without a saved profile it still shows the login screen', () async {
      savedSession(withProfile: false);
      final store = storeAnswering(() => throw const SocketException('offline'));
      await store.init();
      expect(store.isSignedIn, isFalse);
      store.dispose();
    });

    test('a session revoked on the server signs out and forgets the profile', () async {
      savedSession();
      final store = storeAnswering(() => http.Response('{"error":"unauthorized"}', 401));
      await store.init();
      expect(store.isSignedIn, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('me'), isNull);
      expect(prefs.getString('token'), isNull);
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

class FakePush implements PushService {
  FakePush({required this.registration});

  final PushRegistration? registration;
  final badges = <int>[];
  int? tapped;
  final _taps = StreamController<void>.broadcast();

  void tap(int chatId) {
    tapped = chatId;
    _taps.add(null);
  }

  @override
  Stream<void> get taps => _taps.stream;

  @override
  Future<PushRegistration?> register() async => registration;

  @override
  Future<int?> takeTappedChat() async {
    final id = tapped;
    tapped = null;
    return id;
  }

  @override
  Future<void> setBadge(int count) async => badges.add(count);
}

class FakeCallKit implements CallKitService {
  FakeCallKit({required this.token});

  String? token;
  List<int> accepted = [];
  final ended = <int>[];
  final _actions = StreamController<CallKitAction>.broadcast();

  void emit(CallKitAction a) => _actions.add(a);

  @override
  Future<String?> voipToken() async => token;

  @override
  Stream<CallKitAction> get actions => _actions.stream;

  @override
  Future<List<int>> acceptedCalls() async => accepted;

  @override
  Future<void> endCall(int callId) async => ended.add(callId);
}

/// A WebSocket that "connects" when the test says so.
class FakeChannel with StreamChannelMixin<dynamic> implements WebSocketChannel {
  final _in = StreamController<dynamic>();
  final _ready = Completer<void>();

  void connect() => _ready.complete();

  @override
  Future<void> get ready => _ready.future;
  @override
  Stream<dynamic> get stream => _in.stream;
  @override
  WebSocketSink get sink => _FakeSink();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

class _FakeSink implements WebSocketSink {
  @override
  void add(dynamic data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {}
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
  @override
  Future<void> get done => Future.value();
}
