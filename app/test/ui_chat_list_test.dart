import 'package:familygram/data/models.dart';
import 'package:familygram/data/store.dart';
import 'package:familygram/ui/chats/chat_list.dart';
import 'package:familygram/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

const me = User(id: 1, phone: '+79990000001', displayName: 'Я');
const mama = User(id: 2, phone: '+79990000002', displayName: 'Мама');
const papa = User(id: 3, phone: '+79990000003', displayName: 'Папа');

Message msg(int id, int chatId, int sender, String text, {String kind = 'text', FileInfo? file}) =>
    Message(
      id: id,
      chatId: chatId,
      senderId: sender,
      clientId: 'c$id',
      kind: kind,
      text: text,
      file: file,
      createdAt: DateTime.now().millisecondsSinceEpoch - (100 - id) * 1000,
    );

AppStore seeded() {
  final store = AppStore();
  store.debugSeed(me: me, users: const [mama, papa], chats: [
    Chat(
      id: 10,
      kind: 'group',
      title: 'Семья',
      memberIds: const [1, 2, 3],
      lastMessage: msg(50, 10, 2, 'Привет всем'),
      unread: 3,
    ),
    Chat(
      id: 11,
      kind: 'direct',
      title: 'Папа',
      memberIds: const [1, 3],
      lastMessage: msg(40, 11, 1, 'Созвонимся вечером?'),
      othersReadId: 40,
    ),
    Chat(
      id: 12,
      kind: 'direct',
      title: 'Мама',
      memberIds: const [1, 2],
      lastMessage: msg(30, 12, 2, '', kind: 'voice',
          file: const FileInfo(id: 'f', name: 'v.m4a', mime: 'audio/mp4', size: 1, durationMs: 42000)),
      unread: 1,
    ),
  ]);
  return store;
}

Widget app(AppStore store, {void Function(int)? onOpen}) =>
    ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: ChatListView(onOpen: onOpen ?? (_) {})),
      ),
    );

void main() {
  testWidgets('renders rows with titles, prefixes, badges and previews', (t) async {
    await t.pumpWidget(app(seeded()));

    expect(find.text('Чаты'), findsOneWidget);
    expect(find.text('Семья'), findsOneWidget);
    expect(find.text('Папа'), findsOneWidget);
    expect(find.text('Мама'), findsOneWidget);

    // Group: sender prefix; my message: "Вы: " prefix.
    expect(find.text('Мама: Привет всем', findRichText: true), findsOneWidget);
    expect(find.text('Вы: Созвонимся вечером?', findRichText: true), findsOneWidget);
    expect(find.text('Голосовое сообщение, 0:42', findRichText: true), findsOneWidget);

    // Unread badges.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    // My message to Папа was read → double tick.
    expect(find.byIcon(Icons.done_all), findsOneWidget);
  });

  testWidgets('search filters by title', (t) async {
    await t.pumpWidget(app(seeded()));
    await t.enterText(find.byType(TextField), 'пап');
    await t.pump();

    expect(find.text('Папа'), findsOneWidget);
    expect(find.text('Семья'), findsNothing);
    expect(find.text('Мама'), findsNothing);

    await t.enterText(find.byType(TextField), 'zzz');
    await t.pump();
    expect(find.text('Ничего не найдено'), findsOneWidget);
  });

  testWidgets('tapping a row opens the chat', (t) async {
    int? opened;
    await t.pumpWidget(app(seeded(), onOpen: (id) => opened = id));
    await t.tap(find.text('Семья'));
    expect(opened, 10);
  });

  test('previewText covers attachment kinds', () {
    expect(previewText(null), 'Нет сообщений');
    expect(previewText(msg(1, 1, 1, '', kind: 'image')), 'Фотография');
    expect(previewText(msg(1, 1, 1, 'дача', kind: 'image')), 'Фотография, дача');
    expect(previewText(msg(1, 1, 1, '', kind: 'video')), 'Видео');
    expect(
      previewText(msg(1, 1, 1, '', kind: 'file',
          file: const FileInfo(id: 'x', name: 'справка.pdf', mime: 'application/pdf', size: 1))),
      'Документ: справка.pdf',
    );
  });
}
