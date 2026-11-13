import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'call_connection.dart';

/// Colors of the dark in-call screen (from the Call artboard).
class _C {
  static const bg = Color(0xFF16201E);
  static const tile = Color(0xFF1E2B28);
  static const pip = Color(0xFF2F3F3B);
  static const pipBorder = Color(0xFF3E524D);
  static const bar = Color(0xFF101816);
  static const button = Color(0xFF34433F);
  static const muted = Color(0xFFC9D6D2);
}

bool get _isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// In-call screen: shows participants and controls of a LiveKit call.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.join, this.startWithVideo = false, this.connection});

  final CallJoin join;
  final bool startWithVideo;

  /// Already started connection (CallController starts it before the screen
  /// so a call answered on the lock screen talks right away); if null, the
  /// screen connects itself.
  final CallConnection? connection;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  late final AppStore _store = context.read<AppStore>();

  bool _connecting = true;
  bool _reconnecting = false;
  String? _error;
  bool _micOn = true;
  bool _camOn = false;
  bool _speakerOn = false;
  lk.CameraPosition _camPos = lk.CameraPosition.front;
  bool _closing = false;

  DateTime? _talkStart;
  Timer? _ticker;

  Call get _call => _store.activeCall ?? widget.join.call;

  @override
  void initState() {
    super.initState();
    _camOn = widget.startWithVideo;
    _speakerOn = widget.startWithVideo;
    if (widget.join.call.answeredAt != null) {
      _talkStart = DateTime.fromMillisecondsSinceEpoch(widget.join.call.answeredAt!);
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _store.addListener(_onStore);
    _connect();
  }

  Future<void> _connect() async {
    final conn = widget.connection ??
        CallConnection.start(widget.join, video: widget.startWithVideo, forceRelay: _store.forceRelay);
    final room = conn.room;
    _room = room;
    _listener = room.createListener()
      ..on<lk.RoomReconnectingEvent>((_) => _set(() => _reconnecting = true))
      ..on<lk.RoomReconnectedEvent>((_) => _set(() => _reconnecting = false))
      ..on<lk.RoomDisconnectedEvent>((e) {
        if (e.reason != lk.DisconnectReason.clientInitiated) _hangUp();
      })
      ..on<lk.ParticipantConnectedEvent>((_) => _onParticipants())
      ..on<lk.ParticipantDisconnectedEvent>((_) => _onParticipants())
      ..on<lk.TrackSubscribedEvent>((_) => _set(() {}))
      ..on<lk.TrackUnsubscribedEvent>((_) => _set(() {}))
      ..on<lk.TrackMutedEvent>((_) => _set(() {}))
      ..on<lk.TrackUnmutedEvent>((_) => _set(() {}))
      ..on<lk.LocalTrackPublishedEvent>((_) => _set(() {}));
    final r = await conn.ready;
    if (r.error != null) {
      _set(() {
        _connecting = false;
        _error = r.error;
      });
      return;
    }
    _micOn = r.micOn;
    _camOn = r.camOn;
    _deviceWarning = r.deviceWarning;
    // Hung up (or disconnected) while still connecting: nothing to show.
    if (room.connectionState == lk.ConnectionState.disconnected && !_closing) {
      _hangUp();
      return;
    }
    _onParticipants();
    _set(() => _connecting = false);
  }

  /// Keeps header text readable over bright remote video.
  static const _textShadow = [Shadow(color: Color(0xAA000000), blurRadius: 6)];

  /// Non-fatal problem with the microphone or camera, shown under the status.
  String? _deviceWarning;

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  void _onParticipants() {
    final remote = _room?.remoteParticipants.length ?? 0;
    if (remote > 0 && _talkStart == null) _talkStart = DateTime.now();
    _set(() {});
  }

  void _onStore() {
    final c = _store.activeCall;
    // The server ended the call (declined, missed or everyone left).
    if (c != null && c.id == widget.join.call.id && !c.isLive) {
      _hangUp();
    }
    // Hung up on the system call screen (CallKit), e.g. from the lock screen.
    if (_store.callKitEndRequest == widget.join.call.id) {
      _hangUp();
    }
  }

  Future<void> _hangUp() async {
    if (_closing) return;
    _closing = true;
    try {
      await _room?.disconnect();
    } catch (_) {}
    await _store.leaveCall();
    // pop(), not maybePop(): PopScope still holds canPop=false from the last
    // build, so maybePop would be swallowed and the screen would stay open.
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _store.removeListener(_onStore);
    _listener?.dispose();
    if (!_closing) {
      _closing = true;
      _room?.disconnect();
      _store.leaveCall();
    }
    _room?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ controls ---

  Future<void> _toggleMic() async {
    final v = !_micOn;
    _set(() => _micOn = v);
    await _room?.localParticipant?.setMicrophoneEnabled(v);
  }

  Future<void> _toggleCam() async {
    final v = !_camOn;
    _set(() => _camOn = v);
    try {
      await _room?.localParticipant?.setCameraEnabled(
        v,
        cameraCaptureOptions: lk.CameraCaptureOptions(cameraPosition: _camPos),
      );
    } catch (_) {
      _set(() => _camOn = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет доступа к камере')),
        );
      }
    }
  }

  Future<void> _toggleSpeaker() async {
    final v = !_speakerOn;
    _set(() => _speakerOn = v);
    await lk.AudioManager.instance.setSpeakerOutputPreferred(v);
  }

  Future<void> _flip() async {
    final track = _localVideo();
    if (track == null) return;
    final next = _camPos.switched();
    try {
      await track.setCameraPosition(next);
      _set(() => _camPos = next);
    } catch (_) {}
  }

  lk.LocalVideoTrack? _localVideo() {
    for (final pub in _room?.localParticipant?.videoTrackPublications ?? const []) {
      final t = pub.track;
      if (t is lk.LocalVideoTrack && !pub.muted) return t;
    }
    return null;
  }

  // -------------------------------------------------------------- render ---

  String get _title {
    final chat = _store.chatById(_call.chatId);
    return chat?.title ?? 'Звонок';
  }

  String get _status {
    if (_error != null) return 'Ошибка соединения';
    if (_connecting) return 'Соединение…';
    if (_reconnecting) return 'Переподключение…';
    final start = _talkStart;
    if (start == null) {
      return _call.initiatorId == _store.me?.id ? 'Вызов…' : 'Ожидание…';
    }
    return duration(DateTime.now().difference(start).inMilliseconds);
  }

  @override
  Widget build(BuildContext context) {
    final remotes = _room?.remoteParticipants.values.toList() ?? const [];
    final local = _room?.localParticipant;
    final isGroupLayout = remotes.length >= 2;

    return PopScope(
      canPop: _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hangUp();
      },
      child: Scaffold(
        backgroundColor: _C.bg,
        body: Stack(
          children: [
            Positioned.fill(
              child: isGroupLayout
                  ? _grid([...remotes, ?local])
                  : remotes.isEmpty
                      ? _waitingTile()
                      : _tile(remotes.first, big: true),
            ),
            if (!isGroupLayout && local != null && _camOn && _localVideo() != null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 16,
                right: 16,
                child: _pip(local),
              ),
            _header(context),
            Align(alignment: Alignment.bottomCenter, child: _controls(context)),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 140, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w600,
                shadows: _textShadow,
              ),
            ),
            const SizedBox(height: 4),
            Text(_status, style: const TextStyle(color: _C.muted, fontSize: 16, shadows: _textShadow)),
            if (_error == null && _deviceWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _deviceWarning!,
                  style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 14, shadows: _textShadow),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 14, shadows: _textShadow),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _waitingTile() {
    final chat = _store.chatById(_call.chatId);
    final seed = chat == null
        ? _call.chatId
        : chat.isGroup
            ? chat.id
            : chat.memberIds.firstWhere((id) => id != _store.me?.id, orElse: () => chat.id);
    final user = chat != null && !chat.isGroup ? _store.users[seed] : null;
    return Container(
      color: _C.tile,
      alignment: Alignment.center,
      child: Avatar(
        name: _title,
        seed: seed,
        fileId: user?.avatarFileId ?? chat?.avatarFileId,
        size: 168,
      ),
    );
  }

  int _seedOf(lk.Participant p) => int.tryParse(p.identity) ?? p.identity.hashCode;

  String _nameOf(lk.Participant p) {
    final id = int.tryParse(p.identity);
    final user = id == null ? null : _store.users[id];
    if (user != null) return user.displayName;
    return p.name.isNotEmpty ? p.name : 'Участник';
  }

  lk.VideoTrack? _videoOf(lk.Participant p) {
    for (final pub in p.videoTrackPublications) {
      final t = pub.track;
      if (t is lk.VideoTrack && !pub.muted && pub.subscribed) return t;
    }
    return null;
  }

  Widget _tile(lk.Participant p, {bool big = false}) {
    final video = _videoOf(p);
    final id = int.tryParse(p.identity);
    return Container(
      color: _C.tile,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (video != null)
            lk.VideoTrackRenderer(video, fit: lk.VideoViewFit.cover)
          else
            Center(
              child: Avatar(
                name: _nameOf(p),
                seed: _seedOf(p),
                fileId: id == null ? null : _store.users[id]?.avatarFileId,
                size: big ? 168 : 72,
              ),
            ),
          if (!big)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!p.isMicrophoneEnabled())
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.mic_off, size: 14, color: Colors.white),
                      ),
                    Text(
                      p is lk.LocalParticipant ? 'Вы' : _nameOf(p),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _grid(List<lk.Participant> ps) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 96, 8, 140),
        child: LayoutBuilder(builder: (context, c) {
          final cols = ps.length <= 2 ? 1 : (c.maxWidth > 700 ? 3 : 2);
          final rows = (ps.length / cols).ceil();
          final h = (c.maxHeight - (rows - 1) * 8) / rows;
          final w = (c.maxWidth - (cols - 1) * 8) / cols;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in ps)
                SizedBox(
                  width: w,
                  height: h,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: _tile(p),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _pip(lk.LocalParticipant local) {
    final track = _localVideo();
    return Container(
      width: 104,
      height: 148,
      decoration: BoxDecoration(
        color: _C.pip,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _C.pipBorder, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: track == null
          ? const Icon(Icons.person_outline, color: Color(0xFFA9BAB5), size: 34)
          : lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.cover),
    );
  }

  Widget _controls(BuildContext context) {
    final buttons = <Widget>[
      _CallButton(
        icon: _micOn ? Icons.mic_none : Icons.mic_off,
        label: 'Микрофон',
        semantics: _micOn ? 'Выключить микрофон' : 'Включить микрофон',
        active: !_micOn,
        onTap: _toggleMic,
      ),
      _CallButton(
        icon: _camOn ? Icons.videocam_outlined : Icons.videocam_off_outlined,
        label: 'Камера',
        semantics: _camOn ? 'Выключить камеру' : 'Включить камеру',
        active: _camOn,
        onTap: _toggleCam,
      ),
      if (_isMobile)
        _CallButton(
          icon: Icons.volume_up_outlined,
          label: 'Динамик',
          semantics: 'Громкая связь',
          active: _speakerOn,
          onTap: _toggleSpeaker,
        ),
      if (_isMobile)
        _CallButton(
          icon: Icons.flip_camera_ios_outlined,
          label: 'Перевернуть',
          semantics: 'Перевернуть камеру',
          onTap: _camOn ? _flip : null,
        ),
      _CallButton(
        icon: Icons.call_end,
        label: 'Завершить',
        semantics: 'Завершить звонок',
        danger: true,
        onTap: _hangUp,
      ),
    ];
    return Container(
      color: _C.bar,
      padding: EdgeInsets.fromLTRB(12, 20, 12, 20 + MediaQuery.paddingOf(context).bottom),
      child: Center(
        heightFactor: 1, // keep the bar as tall as its buttons, not the screen
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [for (final b in buttons) Expanded(child: b)],
          ),
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.label,
    required this.semantics,
    required this.onTap,
    this.active = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String semantics;
  final VoidCallback? onTap;
  final bool active;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final bg = danger
        ? Fg.danger
        : active
            ? Fg.accentTint
            : _C.button;
    final fg = active && !danger ? Fg.accent : Colors.white;
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                  child: Icon(icon, color: fg, size: danger ? 26 : 24),
                ),
                const SizedBox(height: 8),
                // Five buttons share a ~390pt phone width (~70pt each), so a long
                // label like «Перевернуть» must shrink rather than break mid-word.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
