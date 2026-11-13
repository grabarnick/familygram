import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

/// CallKit's id for a call, derived from the server's call id exactly like
/// the server does (callUUID in server/push.go), so both name the same call.
String callKitUuid(int callId) =>
    '00000000-0000-4000-8000-${callId.toRadixString(16).padLeft(12, '0')}';

/// Inverse of [callKitUuid]; null for a UUID that is not one of ours.
int? callIdFromCallKitUuid(String uuid) {
  const prefix = '00000000-0000-4000-8000-';
  final u = uuid.toLowerCase();
  if (!u.startsWith(prefix)) return null;
  return int.tryParse(u.substring(prefix.length), radix: 16);
}

enum CallKitActionKind { accept, decline, ended, timeout, tokenUpdated }

/// Something the person did on the system call screen.
class CallKitAction {
  const CallKitAction(this.kind, [this.callId]);

  final CallKitActionKind kind;
  final int? callId;

  @override
  String toString() => 'CallKitAction($kind, $callId)';
}

/// The phone's native incoming-call screen (iOS CallKit). The server wakes the
/// app with a VoIP push and the native code (AppDelegate.swift) shows the call
/// there, so it rings even when the app is closed. Null where unsupported.
abstract class CallKitService {
  /// PushKit token for the server's VoIP pushes; null until iOS issues it
  /// (then a [CallKitActionKind.tokenUpdated] action follows).
  Future<String?> voipToken();

  Stream<CallKitAction> get actions;

  /// Calls already accepted on the system screen, e.g. the one that launched
  /// the app before Dart was listening.
  Future<List<int>> acceptedCalls();

  /// Takes the call off the system screen (ended, declined elsewhere…).
  Future<void> endCall(int callId);

  static CallKitService? forPlatform() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? IOSCallKit() : null;
}

class IOSCallKit implements CallKitService {
  @override
  Future<String?> voipToken() async {
    final t = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    return (t == null || t.isEmpty) ? null : t;
  }

  @override
  Stream<CallKitAction> get actions => FlutterCallkitIncoming.onEvent
      .map(_toAction)
      .where((a) => a != null)
      .cast<CallKitAction>();

  static CallKitAction? _toAction(CallEvent? e) => switch (e) {
        CallEventActionCallAccept(:final callKitParams) =>
          CallKitAction(CallKitActionKind.accept, callIdFromCallKitUuid(callKitParams.id)),
        CallEventActionCallDecline(:final callKitParams) =>
          CallKitAction(CallKitActionKind.decline, callIdFromCallKitUuid(callKitParams.id)),
        CallEventActionCallEnded(:final callKitParams) =>
          CallKitAction(CallKitActionKind.ended, callIdFromCallKitUuid(callKitParams.id)),
        CallEventActionCallTimeout(:final id) =>
          CallKitAction(CallKitActionKind.timeout, callIdFromCallKitUuid(id)),
        CallEventActionDidUpdateDevicePushTokenVoip() =>
          const CallKitAction(CallKitActionKind.tokenUpdated),
        _ => null,
      };

  @override
  Future<List<int>> acceptedCalls() async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    return [
      for (final c in calls)
        if (c.isAccepted) ?callIdFromCallKitUuid(c.id),
    ];
  }

  @override
  Future<void> endCall(int callId) => FlutterCallkitIncoming.endCall(callKitUuid(callId));
}
