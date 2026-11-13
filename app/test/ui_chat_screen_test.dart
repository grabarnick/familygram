import 'package:familygram/data/models.dart';
import 'package:familygram/data/store.dart';
import 'package:familygram/ui/chat/chat_screen.dart';
import 'package:familygram/ui/chat/message_bubble.dart';
import 'package:familygram/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  const me = User(id: 1, phone: '+79990000001', displayName: 'Я');
  const mama = User(id: 2, phone: '+79990000002', displayName: 'Мама');
  const papa = User(id: 3, phone: '+79990000003', displayName: 'Папа');
  final now = DateTime.now().millisecondsSinceEpoch;

  AppStore seeded() {
    final store = AppStore();
    store.debugSeed(me: me, users: [mama, papa], chats: [
      const Chat(
        id: 10,
        kind: 'group',
        title: 'Семья',
        memberIds: [1, 2, 3],
        lastReadId: 100,
        othersReadId: 3,
      ),
    ]);
    final cm = store.messagesOf(10)
      ..loaded = true
      ..hasMore = false;
    cm.items.addAll([
      Message(
          id: 1, chatId: 10, senderId: 2, clientId: 'a', kind: 'text',
          text: 'Привет всем', createdAt: now - 60000),
      Message(
          id: 2, chatId: 10, senderId: 3, clientId: 'b', kind: 'text',
          createdAt: now - 50000, deleted: true),
      Message(
          id: 3, chatId: 10, senderId: 1, clientId: 'c', kind: 'text',
          text: 'Отвечаю маме', replyToId: 1, createdAt: now - 40000),
    ]);
    return store;
  }

  Future<void> pump(WidgetTester tester, AppStore store) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ChatScreen(chatId: 10),
      ),
    ));
    await tester.pump();
  }

  testWidgets('renders text bubble, header and date chip', (tester) async {
    await pump(tester, seeded());
    expect(find.text('Семья'), findsOneWidget);
    expect(find.text('3 участника'), findsOneWidget);
    expect(find.text('Сегодня'), findsOneWidget);
    expect(find.text('Привет всем', findRichText: true), findsWidgets);
    expect(find.text('Мама'), findsWidgets); // sender name in group
  });

  testWidgets('renders deleted message placeholder', (tester) async {
    await pump(tester, seeded());
    expect(find.text('Сообщение удалено'), findsOneWidget);
  });

  testWidgets('renders reply quote with original author and text', (tester) async {
    await pump(tester, seeded());
    final quote = find.byType(ReplyQuote);
    expect(quote, findsOneWidget);
    expect(find.descendant(of: quote, matching: find.text('Мама')), findsOneWidget);
    expect(find.descendant(of: quote, matching: find.text('Привет всем')),
        findsOneWidget);
    expect(find.text('Отвечаю маме', findRichText: true), findsOneWidget);
    // My message is read by others (id 3 <= othersReadId 3).
    expect(find.byIcon(Icons.done_all), findsOneWidget);
  });
}
