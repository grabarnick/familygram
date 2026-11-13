import 'package:familygram/data/models.dart';
import 'package:familygram/data/realtime.dart';
import 'package:familygram/data/store.dart';
import 'package:familygram/ui/call/call_text.dart';
import 'package:familygram/ui/calls/calls_screen.dart';
import 'package:familygram/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

const me = User(id: 1, phone: '+79990000001', displayName: 'Я');
const mama = User(id: 2, phone: '+79990000002', displayName: 'Мама');

final now = DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> callJson(int id,
        {int chatId = 11,
        int initiator = 2,
        String state = 'ringing',
        bool video = true,
        List<int> participants = const [],
        int? answeredAt,
        int? endedAt}) =>
    {
      'id': id,
      'chat_id': chatId,
      'initiator_id': initiator,
      'video': video,
      'state': state,
      'participant_ids': participants,
      'created_at': now - 60000,
      'answered_at': answeredAt,
      'ended_at': endedAt,
    };

AppStore seeded() {
  final store = AppStore();
  store.debugSeed(me: me, users: const [mama], chats: const [
    Chat(id: 11, kind: 'direct', title: 'Мама', memberIds: [1, 2]),
  ]);
  return store;
}

void main() {
  group('Call models', () {
    test('Call JSON round-trip', () {
      final j = callJson(7,
          state: 'active', participants: [1, 2], answeredAt: now - 5000);
      final c = Call.fromJson(j);
      expect(c.id, 7);
      expect(c.video, isTrue);
      expect(c.isLive, isTrue);
      expect(c.participantIds, [1, 2]);
      expect(Call.fromJson(c.toJson()).toJson(), c.toJson());
    });

    test('CallJoin and call message parse', () {
      final j = CallJoin.fromJson({
        'call': callJson(3),
        'livekit_url': 'wss://rtc.example.ru',
        'token': 'jwt',
      });
      expect(j.livekitUrl, 'wss://rtc.example.ru');
      expect(j.call.id, 3);

      final m = Message.fromJson({
        'id': 1,
        'chat_id': 11,
        'sender_id': 2,
        'client_id': 'x',
        'kind': 'call',
        'text': '',
        'created_at': now,
        'call': {'id': 3, 'video': true, 'state': 'ended', 'duration_ms': 134000},
      });
      expect(m.call?.durationMs, 134000);
      expect(callMessageText(m), 'Видеозвонок · 2:14');
      final missed = Message.fromJson({
        ...m.toJson(),
        'call': {'id': 4, 'video': false, 'state': 'missed', 'duration_ms': 0},
      });
      expect(callMessageText(missed), 'Пропущенный звонок');
      expect(callMessageMissed(missed), isTrue);
      expect(callMessageText(missed, outgoing: true), 'Звонок без ответа');
    });

    test('ServerInfo.calls', () {
      expect(ServerInfo.fromJson({'name': 'X', 'auth': 'sms', 'calls': true}).calls, isTrue);
      expect(ServerInfo.fromJson({'name': 'X'}).calls, isFalse);
    });
  });

  group('Store call events', () {
    test('ring from someone else sets incomingCall', () {
      final s = seeded();
      s.applyEvent(RealtimeEvent(RealtimeEvent.callRing, callJson(1)));
      expect(s.incomingCall?.id, 1);
      expect(s.liveCalls[11]?.id, 1);
      expect(s.callHistory.single.id, 1);
    });

    test('my own ring is ignored for the incoming overlay', () {
      final s = seeded();
      s.applyEvent(RealtimeEvent(RealtimeEvent.callRing, callJson(1, initiator: 1)));
      expect(s.incomingCall, isNull);
      expect(s.liveCalls[11]?.id, 1);
    });

    test('ended clears incoming and updates history', () {
      final s = seeded();
      s.applyEvent(RealtimeEvent(RealtimeEvent.callRing, callJson(1)));
      s.applyEvent(RealtimeEvent(
          RealtimeEvent.callEnded, callJson(1, state: 'missed', endedAt: now)));
      expect(s.incomingCall, isNull);
      expect(s.liveCalls.containsKey(11), isFalse);
      expect(s.callHistory.single.state, CallState.missed);
    });

    test('answered on another device clears incoming', () {
      final s = seeded();
      s.applyEvent(RealtimeEvent(RealtimeEvent.callRing, callJson(1)));
      s.applyEvent(RealtimeEvent(RealtimeEvent.callUpdated,
          callJson(1, state: 'active', participants: [1, 2], answeredAt: now)));
      expect(s.incomingCall, isNull);
      expect(s.liveCalls[11]?.state, CallState.active);
    });
  });

  group('CallsScreen', () {
    Widget wrap(AppStore s) => ChangeNotifierProvider.value(
          value: s,
          child: MaterialApp(theme: buildTheme(Brightness.light), home: const CallsScreen()),
        );

    testWidgets('shows not-configured state when calls are off', (tester) async {
      await tester.pumpWidget(wrap(seeded()));
      expect(find.text('Звонки не настроены'), findsOneWidget);
    });

    testWidgets('renders history with missed styling', (tester) async {
      final s = seeded()
        ..serverInfo = const ServerInfo(name: 'X', auth: 'sms', calls: true);
      s.callHistory = [
        Call.fromJson(callJson(2, state: 'missed', endedAt: now)),
        Call.fromJson(callJson(1,
            initiator: 1,
            video: false,
            state: 'ended',
            answeredAt: now - 134000,
            endedAt: now)),
      ];
      await tester.pumpWidget(wrap(s));
      expect(find.text('Пропущенный'), findsOneWidget);
      expect(find.text('Исходящий · 2:14'), findsOneWidget);
      expect(find.byKey(const ValueKey('missed')), findsOneWidget);
      expect(find.byKey(const ValueKey('out')), findsOneWidget);
      final missedIcon = tester.widget<Icon>(find.byKey(const ValueKey('missed')));
      expect(missedIcon.color, Theme.of(tester.element(find.byType(CallsScreen))).colorScheme.error);
    });
  });
}
