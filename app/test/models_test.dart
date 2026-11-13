import 'package:familygram/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('User round-trip', () {
    final j = {
      'id': 1,
      'phone': '+79991234567',
      'display_name': 'Мама',
      'avatar_file_id': null,
      'is_admin': true,
    };
    final u = User.fromJson(j);
    expect(u.phone, '+79991234567');
    expect(u.isAdmin, isTrue);
    expect(u.toJson(), j);
  });

  test('Chat with last message and file round-trip', () {
    final file = {
      'id': 'abc',
      'name': 'photo.jpg',
      'mime': 'image/jpeg',
      'size': 10,
      'width': 1280,
      'height': 960,
      'duration_ms': 0,
    };
    final msg = {
      'id': 42,
      'chat_id': 3,
      'sender_id': 1,
      'client_id': 'u-1',
      'kind': 'image',
      'text': 'подпись',
      'file': file,
      'reply_to_id': 7,
      'created_at': 1731400000000,
      'deleted': false,
    };
    final chat = {
      'id': 3,
      'kind': 'group',
      'title': 'Семья',
      'avatar_file_id': null,
      'member_ids': [1, 2, 5],
      'last_message': msg,
      'unread': 2,
      'last_read_id': 40,
      'others_read_id': 41,
    };
    final c = Chat.fromJson(chat);
    expect(c.isGroup, isTrue);
    expect(c.lastMessage!.file!.isImage, isTrue);
    expect(c.lastMessage!.replyToId, 7);
    expect(c.toJson(), chat);
  });

  test('AuthResult and ServerInfo', () {
    final r = AuthResult.fromJson({
      'token': 't',
      'user': {'id': 2, 'phone': '+7', 'display_name': '', 'is_admin': false},
      'is_new': true,
    });
    expect(r.isNew, isTrue);
    expect(ServerInfo.fromJson({'name': 'X', 'auth': 'sms'}).auth, 'sms');
  });

  test('MessageKind.forMime', () {
    expect(MessageKind.forMime('image/png'), 'image');
    expect(MessageKind.forMime('video/mp4'), 'video');
    expect(MessageKind.forMime('audio/m4a', voice: true), 'voice');
    expect(MessageKind.forMime('application/pdf'), 'file');
  });
}
