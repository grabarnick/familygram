import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A phone's push registration, sent to the server (POST /api/devices).
class PushRegistration {
  const PushRegistration({required this.platform, required this.token, required this.sandbox});

  final String platform;
  final String token;

  /// Development-signed iOS build: the server must use the APNs sandbox.
  final bool sandbox;
}

/// Push notifications on this device. Null where unsupported (web, Android
/// for now); tests pass a fake.
abstract class PushService {
  /// Asks permission and returns the device token, or null if the person
  /// declined notifications.
  Future<PushRegistration?> register();

  /// Fires when a notification was tapped; then call [takeTappedChat].
  Stream<void> get taps;

  /// Chat of the last tapped notification (once), including the tap that
  /// launched the app.
  Future<int?> takeTappedChat();

  /// Number on the app icon.
  Future<void> setBadge(int count);

  static PushService? forPlatform() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? ApplePush() : null;
}

/// APNs via the native bridge in ios/Runner/AppDelegate.swift (no Firebase).
class ApplePush implements PushService {
  ApplePush() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'tapped') _taps.add(null);
    });
  }

  static const _channel = MethodChannel('familygram/push');
  final _taps = StreamController<void>.broadcast();

  @override
  Stream<void> get taps => _taps.stream;

  @override
  Future<PushRegistration?> register() async {
    final r = await _channel.invokeMapMethod<String, dynamic>('register');
    if (r == null) return null;
    return PushRegistration(
      platform: 'ios',
      token: r['token'] as String,
      sandbox: r['sandbox'] == true,
    );
  }

  @override
  Future<int?> takeTappedChat() => _channel.invokeMethod<int>('takeTappedChat');

  @override
  Future<void> setBadge(int count) => _channel.invokeMethod('setBadge', count);
}
