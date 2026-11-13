import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'models.dart';

/// Error returned by the server (`{"error": "..."}`) or by the network.
class ApiException implements Exception {
  final int status;
  final String message;

  /// Seconds to wait before retrying (from a 429 `retry_after`).
  final int? retryAfter;

  /// True when a 429 means "a code was already sent to this phone" (the
  /// per-phone cooldown), as opposed to a generic rate limit.
  final bool codeSent;

  const ApiException(this.status, this.message, {this.retryAfter, this.codeSent = false});

  bool get isUnauthorized => status == 401;
  bool get isNetwork => status == 0;

  @override
  String toString() => message;
}

/// Thin REST client for the Familygram server.
class ApiClient {
  ApiClient({required String baseUrl, this.token, http.Client? client})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _http = client ?? http.Client();

  final String baseUrl;
  String? token;
  final http.Client _http;

  /// Accepts "family.example.ru", "https://family.example.ru/" etc.
  static String normalizeBaseUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// Absolute URL of a WebSocket endpoint.
  Uri get wsUri {
    final u = Uri.parse(baseUrl);
    return u.replace(
      scheme: u.scheme == 'https' ? 'wss' : 'ws',
      path: '${u.path}/api/ws',
      queryParameters: {'token': token ?? ''},
    );
  }

  /// URL usable in Image.network / players; auth via query token.
  String fileUrl(String fileId) =>
      _uri('/api/files/$fileId', {'token': token ?? ''}).toString();

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, _uri(path, query))..headers.addAll(_headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    try {
      final resp = await http.Response.fromStream(await _http.send(req));
      return _decode(resp);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'Нет соединения с сервером');
    }
  }

  dynamic _decode(http.Response resp) {
    final text = utf8.decode(resp.bodyBytes);
    dynamic data;
    if (text.isNotEmpty) {
      try {
        data = jsonDecode(text);
      } catch (_) {
        data = null;
      }
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) return data;
    final map = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    final retry = map['retry_after'];
    throw ApiException(
      resp.statusCode,
      map['error'] as String? ?? 'Ошибка сервера (${resp.statusCode})',
      retryAfter: retry is num ? retry.toInt() : null,
      codeSent: map['code_sent'] == true,
    );
  }

  List<Map<String, dynamic>> _list(dynamic d) =>
      (d as List? ?? const []).cast<Map<String, dynamic>>();

  // ---- server & auth ----

  /// Registers this phone for push notifications (tied to the session).
  Future<void> registerDevice({required String platform, required String token, required bool sandbox}) async {
    await _send('POST', '/api/devices', body: {'platform': platform, 'token': token, 'sandbox': sandbox});
  }

  Future<ServerInfo> info() async =>
      ServerInfo.fromJson(await _send('GET', '/api/info') as Map<String, dynamic>);

  /// Asks the server to send an SMS code. Returns seconds until a new code
  /// may be requested. Throws [ApiException] (403 not allowed, 429 too soon
  /// with [ApiException.retryAfter]).
  Future<int> requestCode(String phone) async {
    final d = await _send('POST', '/api/auth/request-code', body: {'phone': phone});
    final r = (d as Map<String, dynamic>?)?['retry_after'];
    return r is num ? r.toInt() : 60;
  }

  Future<AuthResult> verify(String phone, String code) async {
    final d = await _send('POST', '/api/auth/verify',
        body: {'phone': phone, 'code': code});
    final res = AuthResult.fromJson(d as Map<String, dynamic>);
    token = res.token;
    return res;
  }

  Future<void> logout() async {
    try {
      await _send('POST', '/api/auth/logout');
    } finally {
      token = null;
    }
  }

  Future<User> me() async =>
      User.fromJson(await _send('GET', '/api/me') as Map<String, dynamic>);

  Future<User> updateMe({String? displayName, String? avatarFileId}) async {
    final d = await _send('PATCH', '/api/me', body: {
      'display_name': ?displayName,
      'avatar_file_id': ?avatarFileId,
    });
    return User.fromJson(d as Map<String, dynamic>);
  }

  Future<List<User>> users() async =>
      _list(await _send('GET', '/api/users')).map(User.fromJson).toList();

  // ---- admin: allowed phones ----

  Future<List<AllowedPhone>> listPhones() async =>
      _list(await _send('GET', '/api/phones')).map(AllowedPhone.fromJson).toList();

  Future<void> addPhone(String phone, {String? displayName}) => _send(
      'POST', '/api/phones',
      body: {'phone': phone, 'display_name': ?displayName});

  Future<void> removePhone(String phone) =>
      _send('DELETE', '/api/phones/${Uri.encodeComponent(phone)}');

  // ---- chats & messages ----

  Future<List<Chat>> chats() async =>
      _list(await _send('GET', '/api/chats')).map(Chat.fromJson).toList();

  Future<Chat> createDirect(int userId) async => Chat.fromJson(await _send(
      'POST', '/api/chats',
      body: {'kind': 'direct', 'user_id': userId}) as Map<String, dynamic>);

  Future<Chat> createGroup(String title, List<int> memberIds) async =>
      Chat.fromJson(await _send('POST', '/api/chats', body: {
        'kind': 'group',
        'title': title,
        'member_ids': memberIds,
      }) as Map<String, dynamic>);

  /// Messages in ascending id order, older than [before] when given.
  Future<List<Message>> messages(int chatId, {int? before, int limit = 50}) async =>
      _list(await _send('GET', '/api/chats/$chatId/messages', query: {
        if (before != null) 'before': '$before',
        'limit': '$limit',
      })).map(Message.fromJson).toList();

  Future<Message> sendMessage(
    int chatId, {
    required String clientId,
    String text = '',
    String? fileId,
    String? kind,
    int? replyToId,
  }) async =>
      Message.fromJson(await _send('POST', '/api/chats/$chatId/messages', body: {
        'client_id': clientId,
        'text': text,
        'file_id': ?fileId,
        'kind': ?kind,
        'reply_to_id': ?replyToId,
      }) as Map<String, dynamic>);

  Future<void> deleteMessage(int messageId) =>
      _send('DELETE', '/api/messages/$messageId');

  Future<void> markRead(int chatId, int messageId) =>
      _send('POST', '/api/chats/$chatId/read', body: {'message_id': messageId});

  // ---- files ----

  /// Uploads bytes (works on web, where there are no file paths).
  Future<FileInfo> uploadFile(
    Uint8List bytes, {
    required String filename,
    String? mime,
    int? width,
    int? height,
    int? durationMs,
  }) async {
    final req = http.MultipartRequest('POST', _uri('/api/files'))
      ..headers.addAll(_headers)
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: mime != null ? MediaType.parse(mime) : null,
      ));
    if (width != null) req.fields['width'] = '$width';
    if (height != null) req.fields['height'] = '$height';
    if (durationMs != null) req.fields['duration_ms'] = '$durationMs';
    try {
      final resp = await http.Response.fromStream(await _http.send(req));
      return FileInfo.fromJson(_decode(resp) as Map<String, dynamic>);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(0, 'Не удалось загрузить файл');
    }
  }

  // ---- calls ----

  Future<CallJoin> startCall(int chatId, {required bool video}) async =>
      CallJoin.fromJson(await _send('POST', '/api/chats/$chatId/call',
          body: {'video': video}) as Map<String, dynamic>);

  Future<CallJoin> joinCall(int callId) async => CallJoin.fromJson(
      await _send('POST', '/api/calls/$callId/join') as Map<String, dynamic>);

  Future<void> declineCall(int callId) => _send('POST', '/api/calls/$callId/decline');

  Future<void> leaveCall(int callId) => _send('POST', '/api/calls/$callId/leave');

  Future<List<Call>> calls({int limit = 50}) async =>
      _list(await _send('GET', '/api/calls', query: {'limit': '$limit'}))
          .map(Call.fromJson)
          .toList();
}
