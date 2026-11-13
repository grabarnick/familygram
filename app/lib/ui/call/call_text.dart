import '../../data/models.dart';
import '../format.dart';

/// Text for a kind "call" message, e.g. "Видеозвонок · 2:14" or
/// "Пропущенный звонок". [outgoing] is from the viewer's perspective.
String callMessageText(Message m, {bool outgoing = false}) {
  final c = m.call;
  final video = c?.video ?? false;
  final noun = video ? 'видеозвонок' : 'звонок';
  final cap = video ? 'Видеозвонок' : 'Звонок';
  if (c == null) return m.text.isNotEmpty ? m.text : cap;
  if (c.state == CallState.declined) {
    return outgoing ? '$cap отклонён' : 'Отклонённый $noun';
  }
  if (c.isMissed || c.durationMs <= 0) {
    return outgoing ? '$cap без ответа' : 'Пропущенный $noun';
  }
  return '$cap · ${duration(c.durationMs)}';
}

/// Whether the call message should be shown as missed (red) for the viewer.
bool callMessageMissed(Message m, {bool outgoing = false}) {
  final c = m.call;
  if (c == null || outgoing) return false;
  return c.isMissed || c.durationMs <= 0;
}
