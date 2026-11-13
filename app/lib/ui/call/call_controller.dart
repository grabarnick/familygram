import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/api.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import 'call_screen.dart';

/// Root navigator, so calls can be opened from anywhere (incoming overlay).
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Root messenger, so snack bars work from the incoming-call overlay too.
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Starts, accepts and joins calls and opens the in-call screen.
class CallController {
  CallController._();

  static bool _screenOpen = false;
  static bool get inCallScreen => _screenOpen;

  static AppStore _store(BuildContext context) => context.read<AppStore>();

  /// Outgoing call (or joins the call already running in [chatId]).
  static Future<void> start(BuildContext context, int chatId, {required bool video}) =>
      _open(context, () => _store(context).startCall(chatId, video: video), video);

  /// Accepts an incoming call or joins an active one.
  static Future<void> join(BuildContext context, Call call) =>
      _open(context, () => _store(context).joinCall(call), call.video);

  static Future<void> _open(
      BuildContext context, Future<CallJoin> Function() connect, bool video) async {
    if (_screenOpen) {
      _snack(context, 'Вы уже в звонке');
      return;
    }
    final store = _store(context);
    if (!store.callsEnabled) {
      _snack(context, 'Звонки не настроены на этом сервере');
      return;
    }
    final nav = appNavigatorKey.currentState ?? Navigator.of(context);
    final messenger = appMessengerKey.currentState ?? ScaffoldMessenger.maybeOf(context);
    final CallJoin join;
    try {
      join = await connect();
    } on ApiException catch (e) {
      // 409: the call ended before we answered.
      if (e.status == 409) store.dismissIncoming();
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    _screenOpen = true;
    try {
      await nav.push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => CallScreen(join: join, startWithVideo: video),
      ));
    } finally {
      _screenOpen = false;
    }
  }

  static void _snack(BuildContext context, String text) =>
      (appMessengerKey.currentState ?? ScaffoldMessenger.maybeOf(context))
          ?.showSnackBar(SnackBar(content: Text(text)));
}
