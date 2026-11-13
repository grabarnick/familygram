import 'dart:math' as math;

// Data models matching the server JSON contract (docs/ARCHITECTURE.md).
// All keys are snake_case, timestamps are unix milliseconds.

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
int? _intOrNull(Object? v) => v == null ? null : _int(v);

class User {
  final int id;
  final String phone;
  final String displayName;
  final String? avatarFileId;
  final bool isAdmin;

  const User({
    required this.id,
    required this.phone,
    required this.displayName,
    this.avatarFileId,
    this.isAdmin = false,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: _int(j['id']),
    phone: j['phone'] as String? ?? '',
    displayName: j['display_name'] as String? ?? '',
    avatarFileId: j['avatar_file_id'] as String?,
    isAdmin: j['is_admin'] == true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'phone': phone,
    'display_name': displayName,
    'avatar_file_id': avatarFileId,
    'is_admin': isAdmin,
  };

  User copyWith({String? displayName, String? avatarFileId}) => User(
    id: id,
    phone: phone,
    displayName: displayName ?? this.displayName,
    avatarFileId: avatarFileId ?? this.avatarFileId,
    isAdmin: isAdmin,
  );
}

class FileInfo {
  final String id;
  final String name;
  final String mime;
  final int size;
  final int width;
  final int height;
  final int durationMs;

  const FileInfo({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
  });

  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');

  factory FileInfo.fromJson(Map<String, dynamic> j) => FileInfo(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    mime: j['mime'] as String? ?? 'application/octet-stream',
    size: _int(j['size']),
    width: _int(j['width']),
    height: _int(j['height']),
    durationMs: _int(j['duration_ms']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'size': size,
    'width': width,
    'height': height,
    'duration_ms': durationMs,
  };
}

/// Message kinds as sent by the server.
class MessageKind {
  static const text = 'text';
  static const image = 'image';
  static const video = 'video';
  static const file = 'file';
  static const voice = 'voice';
  static const call = 'call';

  /// Picks a kind for an attachment by its MIME type.
  static String forMime(String mime, {bool voice = false}) {
    if (voice) return MessageKind.voice;
    if (mime.startsWith('image/')) return MessageKind.image;
    if (mime.startsWith('video/')) return MessageKind.video;
    return MessageKind.file;
  }
}

/// Local delivery state; server messages are always [sent].
enum SendState { sent, pending, failed }

class Message {
  /// Server id. Optimistic (unsent) messages use a negative temporary id.
  final int id;
  final int chatId;
  final int senderId;
  final String clientId;
  final String kind;
  final String text;
  final FileInfo? file;
  final int? replyToId;
  final int createdAt;
  final bool deleted;
  final SendState state;

  /// Summary of a finished call for kind "call".
  final CallSummary? call;

  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.clientId,
    required this.kind,
    this.text = '',
    this.file,
    this.replyToId,
    required this.createdAt,
    this.deleted = false,
    this.state = SendState.sent,
    this.call,
  });

  bool get isLocal => state != SendState.sent;
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(createdAt);

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: _int(j['id']),
    chatId: _int(j['chat_id']),
    senderId: _int(j['sender_id']),
    clientId: j['client_id'] as String? ?? '',
    kind: j['kind'] as String? ?? MessageKind.text,
    text: j['text'] as String? ?? '',
    file: j['file'] is Map<String, dynamic>
        ? FileInfo.fromJson(j['file'] as Map<String, dynamic>)
        : null,
    replyToId: _intOrNull(j['reply_to_id']),
    createdAt: _int(j['created_at']),
    deleted: j['deleted'] == true,
    call: j['call'] is Map<String, dynamic>
        ? CallSummary.fromJson(j['call'] as Map<String, dynamic>)
        : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'chat_id': chatId,
    'sender_id': senderId,
    'client_id': clientId,
    'kind': kind,
    'text': text,
    'file': file?.toJson(),
    'reply_to_id': replyToId,
    'created_at': createdAt,
    'deleted': deleted,
    if (call != null) 'call': call!.toJson(),
  };

  Message copyWith({SendState? state, bool? deleted, String? text}) => Message(
    id: id,
    chatId: chatId,
    senderId: senderId,
    clientId: clientId,
    kind: kind,
    text: text ?? this.text,
    file: file,
    replyToId: replyToId,
    createdAt: createdAt,
    deleted: deleted ?? this.deleted,
    state: state ?? this.state,
    call: call,
  );
}

class Chat {
  final int id;
  final String kind; // direct | group
  final String title;
  final String? avatarFileId;
  final List<int> memberIds;
  final Message? lastMessage;
  final int unread;
  final int lastReadId;
  final int othersReadId;

  const Chat({
    required this.id,
    required this.kind,
    required this.title,
    this.avatarFileId,
    this.memberIds = const [],
    this.lastMessage,
    this.unread = 0,
    this.lastReadId = 0,
    this.othersReadId = 0,
  });

  bool get isGroup => kind == 'group';

  /// Sort key: time of last activity.
  int get activityAt => lastMessage?.createdAt ?? 0;

  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
    id: _int(j['id']),
    kind: j['kind'] as String? ?? 'direct',
    title: j['title'] as String? ?? '',
    avatarFileId: j['avatar_file_id'] as String?,
    memberIds: (j['member_ids'] as List? ?? const [])
        .map((e) => _int(e))
        .toList(),
    lastMessage: j['last_message'] is Map<String, dynamic>
        ? Message.fromJson(j['last_message'] as Map<String, dynamic>)
        : null,
    unread: _int(j['unread']),
    lastReadId: _int(j['last_read_id']),
    othersReadId: _int(j['others_read_id']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'avatar_file_id': avatarFileId,
    'member_ids': memberIds,
    'last_message': lastMessage?.toJson(),
    'unread': unread,
    'last_read_id': lastReadId,
    'others_read_id': othersReadId,
  };

  Chat copyWith({
    Message? lastMessage,
    bool clearLastMessage = false,
    int? unread,
    int? lastReadId,
    int? othersReadId,
  }) => Chat(
    id: id,
    kind: kind,
    title: title,
    avatarFileId: avatarFileId,
    memberIds: memberIds,
    lastMessage: clearLastMessage ? null : (lastMessage ?? this.lastMessage),
    unread: unread ?? this.unread,
    lastReadId: lastReadId ?? this.lastReadId,
    othersReadId: othersReadId ?? this.othersReadId,
  );
}

class ServerInfo {
  final String name;

  /// Sign-in method; currently always "sms".
  final String auth;

  /// Whether the server has LiveKit configured.
  final bool calls;

  const ServerInfo({
    required this.name,
    required this.auth,
    this.calls = false,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
    name: j['name'] as String? ?? 'Familygram',
    auth: j['auth'] as String? ?? 'sms',
    calls: j['calls'] == true,
  );
}

class AuthResult {
  final String token;
  final User user;

  /// True when the account was just created and still needs a name.
  final bool isNew;
  const AuthResult(this.token, this.user, {this.isNew = false});

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
    j['token'] as String,
    User.fromJson(j['user'] as Map<String, dynamic>),
    isNew: j['is_new'] == true,
  );
}

/// A phone number allowed to sign in (admin list).
class AllowedPhone {
  final String phone;
  final String displayName;
  final bool registered;
  const AllowedPhone(this.phone, this.displayName, this.registered);

  factory AllowedPhone.fromJson(Map<String, dynamic> j) => AllowedPhone(
    j['phone'] as String? ?? '',
    j['display_name'] as String? ?? '',
    j['registered'] == true,
  );
}

/// Call states as sent by the server.
class CallState {
  static const ringing = 'ringing';
  static const active = 'active';
  static const ended = 'ended';
  static const missed = 'missed';
  static const declined = 'declined';
}

class Call {
  final int id;
  final int chatId;
  final int initiatorId;
  final bool video;
  final String state;
  final List<int> participantIds;
  final int createdAt;
  final int? answeredAt;
  final int? endedAt;

  const Call({
    required this.id,
    required this.chatId,
    required this.initiatorId,
    required this.video,
    required this.state,
    this.participantIds = const [],
    required this.createdAt,
    this.answeredAt,
    this.endedAt,
  });

  bool get isLive => state == CallState.ringing || state == CallState.active;
  bool get isMissed => state == CallState.missed;

  /// Talk time; zero when never answered.
  int get durationMs => answeredAt == null
      ? 0
      // No clamp(0, 1 << 62): on the web shifts are 32-bit, so that bound is 0.
      : math.max(
          0,
          (endedAt ?? DateTime.now().millisecondsSinceEpoch) - answeredAt!,
        );

  factory Call.fromJson(Map<String, dynamic> j) => Call(
    id: _int(j['id']),
    chatId: _int(j['chat_id']),
    initiatorId: _int(j['initiator_id']),
    video: j['video'] == true,
    state: j['state'] as String? ?? CallState.ended,
    participantIds: (j['participant_ids'] as List? ?? const [])
        .map(_int)
        .toList(),
    createdAt: _int(j['created_at']),
    answeredAt: _intOrNull(j['answered_at']),
    endedAt: _intOrNull(j['ended_at']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'chat_id': chatId,
    'initiator_id': initiatorId,
    'video': video,
    'state': state,
    'participant_ids': participantIds,
    'created_at': createdAt,
    'answered_at': answeredAt,
    'ended_at': endedAt,
  };
}

/// Response of start/join: the call plus LiveKit credentials.
class CallJoin {
  final Call call;
  final String livekitUrl;
  final String token;
  const CallJoin(this.call, this.livekitUrl, this.token);

  factory CallJoin.fromJson(Map<String, dynamic> j) => CallJoin(
    Call.fromJson(j['call'] as Map<String, dynamic>),
    j['livekit_url'] as String? ?? '',
    j['token'] as String? ?? '',
  );
}

/// The `call` field of a kind "call" message.
class CallSummary {
  final int id;
  final bool video;
  final String state;
  final int durationMs;
  const CallSummary({
    required this.id,
    required this.video,
    required this.state,
    this.durationMs = 0,
  });

  bool get isMissed => state == CallState.missed || state == CallState.declined;

  factory CallSummary.fromJson(Map<String, dynamic> j) => CallSummary(
    id: _int(j['id']),
    video: j['video'] == true,
    state: j['state'] as String? ?? CallState.ended,
    durationMs: _int(j['duration_ms']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'video': video,
    'state': state,
    'duration_ms': durationMs,
  };
}
