import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../data/models.dart';

bool get _isMobile =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

/// How connecting to the call went.
class CallConnectResult {
  const CallConnectResult({this.error, this.deviceWarning, this.micOn = true, this.camOn = false});

  /// Could not connect at all.
  final String? error;

  /// Connected, but the microphone or camera could not be used.
  final String? deviceWarning;
  final bool micOn;
  final bool camOn;
}

/// The LiveKit connection of one call, started independently of the call
/// screen: a call answered on the lock screen (CallKit) must start talking
/// before the app draws anything, and iOS draws nothing while it is locked.
class CallConnection {
  CallConnection._(this.room, this.ready);

  final lk.Room room;

  /// Completes when connected (or failed); never throws.
  final Future<CallConnectResult> ready;

  static CallConnection start(
    CallJoin join, {
    required bool video,
    required bool forceRelay,
  }) {
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
    );
    return CallConnection._(room, _connect(room, join, video: video, forceRelay: forceRelay));
  }

  static Future<CallConnectResult> _connect(
    lk.Room room,
    CallJoin join, {
    required bool video,
    required bool forceRelay,
  }) async {
    try {
      await room.connect(
        join.livekitUrl,
        join.token,
        connectOptions: lk.ConnectOptions(
          rtcConfiguration: lk.RTCConfiguration(
            iceTransportPolicy: forceRelay ? lk.RTCIceTransportPolicy.relay : lk.RTCIceTransportPolicy.all,
          ),
        ),
      );
    } catch (_) {
      return const CallConnectResult(
        error: 'Не удалось подключиться к звонку. '
            'Попробуйте включить «Звонки только через сервер» в настройках.',
        micOn: false,
      );
    }
    // Device problems must not look like a broken connection: the call goes on.
    var micOn = true;
    var camOn = video;
    String? warning;
    try {
      await room.localParticipant?.setMicrophoneEnabled(true);
    } catch (_) {
      micOn = false;
      warning = 'Нет доступа к микрофону — проверьте разрешения';
    }
    try {
      if (camOn) {
        try {
          await room.localParticipant?.setCameraEnabled(true);
        } catch (_) {
          camOn = false;
          warning ??= 'Нет доступа к камере — проверьте разрешения';
        }
      }
      if (_isMobile) {
        await lk.AudioManager.instance.setSpeakerOutputPreferred(video);
      }
    } catch (_) {}
    return CallConnectResult(deviceWarning: warning, micOn: micOn, camOn: camOn);
  }
}
