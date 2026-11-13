import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../widgets/avatar.dart';
import 'call_controller.dart';

/// Shows [IncomingCallOverlay] above the whole app while a call is ringing.
class IncomingCallLayer extends StatelessWidget {
  const IncomingCallLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final call = context.select<AppStore, Call?>((s) => s.incomingCall);
    return Stack(
      children: [
        child,
        if (call != null && !CallController.inCallScreen)
          Positioned.fill(child: IncomingCallOverlay(call: call)),
      ],
    );
  }
}

/// Full-screen "incoming call" card with accept / decline.
class IncomingCallOverlay extends StatelessWidget {
  const IncomingCallOverlay({super.key, required this.call});

  final Call call;

  static const _bg = Color(0xFF16201E);
  static const _accept = Color(0xFF16A34A);
  static const _decline = Color(0xFFDC2626);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chat = store.chatById(call.chatId);
    final caller = store.users[call.initiatorId];
    final callerName = caller?.displayName ?? store.userName(call.initiatorId);
    final isGroup = chat?.isGroup == true;
    final title = isGroup ? (chat?.title ?? callerName) : callerName;
    final kind = call.video ? 'Входящий видеозвонок' : 'Входящий аудиозвонок';

    return Material(
      color: _bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 40),
          child: Column(
            children: [
              Text(kind, style: const TextStyle(color: Color(0xFFC9D6D2), fontSize: 16)),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (isGroup) ...[
                const SizedBox(height: 6),
                Text('Звонит $callerName',
                    style: const TextStyle(color: Color(0xFFC9D6D2), fontSize: 15)),
              ],
              const Spacer(),
              Avatar(
                name: title,
                seed: isGroup ? call.chatId : call.initiatorId,
                fileId: isGroup ? chat?.avatarFileId : caller?.avatarFileId,
                size: 168,
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundAction(
                    color: _decline,
                    icon: Icons.call_end,
                    label: 'Отклонить',
                    onTap: () => context.read<AppStore>().declineIncoming(),
                  ),
                  _RoundAction(
                    color: _accept,
                    icon: call.video ? Icons.videocam : Icons.call,
                    label: 'Принять',
                    onTap: () => CallController.join(context, call),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 72,
                height: 72,
                child: Icon(icon, color: Colors.white, size: 32),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      ],
    );
  }
}
