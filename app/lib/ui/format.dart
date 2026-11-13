import 'package:intl/intl.dart';

/// Short time for chat list: "12:40", "Вчера", "Пн", "12.03.25".
String chatListTime(int ms, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return DateFormat('HH:mm').format(t);
  if (diff == 1) return 'Вчера';
  if (diff < 7) return const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'][t.weekday - 1];
  return DateFormat('dd.MM.yy').format(t);
}

/// Time inside a bubble: "12:40".
String bubbleTime(int ms) =>
    DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms));

/// Date chip between messages: "Сегодня", "Вчера", "12 марта", "12 марта 2024".
String dateChip(int ms, {DateTime? now}) {
  const months = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
  ];
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final diff = DateTime(n.year, n.month, n.day)
      .difference(DateTime(t.year, t.month, t.day))
      .inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  final base = '${t.day} ${months[t.month - 1]}';
  return t.year == n.year ? base : '$base ${t.year}';
}

/// "0:42", "12:05".
String duration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// "1,2 МБ", "340 КБ".
String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} КБ';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0).replaceAll('.', ',')} МБ';
}

/// "+7 999 123-45-67" for Russian numbers, otherwise unchanged.
String prettyPhone(String e164) {
  final m = RegExp(r'^\+7(\d{3})(\d{3})(\d{2})(\d{2})$').firstMatch(e164);
  if (m == null) return e164;
  return '+7 ${m[1]} ${m[2]}-${m[3]}-${m[4]}';
}
