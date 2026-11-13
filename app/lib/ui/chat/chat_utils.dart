import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models.dart';
import '../theme.dart';
import '../call/call_text.dart';

/// "1 участник", "3 участника", "5 участников".
String participants(int n) {
  final mod10 = n % 10, mod100 = n % 100;
  final word = (mod10 == 1 && mod100 != 11)
      ? 'участник'
      : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
          ? 'участника'
          : 'участников';
  return '$n $word';
}

/// One-line description of a message for reply previews.
String messageSnippet(Message m) {
  if (m.deleted) return 'Сообщение удалено';
  final caption = m.text.trim();
  switch (m.kind) {
    case MessageKind.image:
      return caption.isNotEmpty ? 'Фото · $caption' : 'Фото';
    case MessageKind.video:
      return caption.isNotEmpty ? 'Видео · $caption' : 'Видео';
    case MessageKind.voice:
      return 'Голосовое сообщение';
    case MessageKind.file:
      return m.file?.name ?? 'Файл';
    case MessageKind.call:
      return callMessageText(m);
    default:
      return caption;
  }
}

/// Stable color for a sender name in group chats.
Color senderColor(int userId) =>
    Fg.avatarColors[userId.abs() % Fg.avatarColors.length];

/// True when the platform is a touch phone/tablet (not web, not desktop).
bool get isTouchPlatform {
  final p = defaultTargetPlatform;
  return !kIsWeb && (p == TargetPlatform.iOS || p == TargetPlatform.android);
}

bool sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a);
  final y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}
