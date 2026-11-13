import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

/// An event from the server: `{"type": "...", "data": {...}}`.
class RealtimeEvent {
  final String type;
  final Map<String, dynamic> data;
  const RealtimeEvent(this.type, this.data);

  static const messageNew = 'message.new';
  static const messageDeleted = 'message.deleted';
  static const chatNew = 'chat.new';
  static const chatRead = 'chat.read';
  static const typing = 'typing';
  static const callRing = 'call.ring';
  static const callUpdated = 'call.updated';
  static const callEnded = 'call.ended';
}

enum ConnectionStatus { disconnected, connecting, connected }

/// WebSocket connection to /api/ws with automatic reconnect and backoff.
class Realtime {
  Realtime(this._uriBuilder, {WebSocketChannel Function(Uri)? connector})
      : _connector = connector ?? WebSocketChannel.connect;

  /// Built on every (re)connect so a refreshed token is picked up.
  final Uri Function() _uriBuilder;
  final WebSocketChannel Function(Uri) _connector;

  final _events = StreamController<RealtimeEvent>.broadcast();
  final _status = StreamController<ConnectionStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _running = false;
  ConnectionStatus _current = ConnectionStatus.disconnected;

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<ConnectionStatus> get statusChanges => _status.stream;
  ConnectionStatus get status => _current;

  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _setStatus(ConnectionStatus.disconnected);
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _status.close();
  }

  /// Reconnects immediately if not connected, skipping the backoff delay.
  /// Used when the app returns to the foreground: after iOS suspended it the
  /// socket is gone, and waiting up to 30s would miss an incoming call.
  void reconnectNow() {
    if (!_running) return;
    if (_current == ConnectionStatus.connected ||
        _current == ConnectionStatus.connecting) {
      return;
    }
    _reconnectTimer?.cancel();
    _attempt = 0;
    _connect();
  }

  void sendTyping(int chatId) => _send('typing', {'chat_id': chatId});

  void _send(String type, Map<String, dynamic> data) {
    if (_current != ConnectionStatus.connected) return;
    _channel?.sink.add(jsonEncode({'type': type, 'data': data}));
  }

  void _setStatus(ConnectionStatus s) {
    if (_current == s) return;
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  Future<void> _connect() async {
    if (!_running) return;
    _setStatus(ConnectionStatus.connecting);
    try {
      final ch = _connector(_uriBuilder());
      _channel = ch;
      await ch.ready;
      if (!_running) return;
      _attempt = 0;
      _setStatus(ConnectionStatus.connected);
      _sub = ch.stream.listen(
        _onData,
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic> && j['type'] is String) {
        final data = j['data'];
        _events.add(RealtimeEvent(
            j['type'] as String, data is Map<String, dynamic> ? data : const {}));
      }
    } catch (_) {
      // Ignore malformed frames.
    }
  }

  void _scheduleReconnect() {
    _setStatus(ConnectionStatus.disconnected);
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (!_running) return;
    _reconnectTimer?.cancel();
    // 1s, 2s, 4s … capped at 30s, with jitter.
    final base = min(30, 1 << min(_attempt, 5));
    _attempt++;
    final delay = Duration(milliseconds: base * 1000 + Random().nextInt(500));
    _reconnectTimer = Timer(delay, _connect);
  }
}
