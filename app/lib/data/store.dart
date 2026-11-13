import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'models.dart';
import 'realtime.dart';

/// Messages loaded for one chat, ascending by id (local unsent ones last).
class ChatMessages {
  final List<Message> items = [];
  bool hasMore = true;
  bool loading = false;
  bool loaded = false;
}

typedef ApiFactory = ApiClient Function(String baseUrl, String? token);
typedef RealtimeFactory = Realtime Function(ApiClient api);

/// Whole client state: session, users, chats, messages, realtime.
class AppStore extends ChangeNotifier {
  AppStore({ApiFactory? apiFactory, RealtimeFactory? realtimeFactory})
      : _apiFactory = apiFactory ??
            ((url, token) => ApiClient(baseUrl: url, token: token)),
        _realtimeFactory =
            realtimeFactory ?? ((api) => Realtime(() => api.wsUri));

  static const _kServer = 'server_url';
  static const _kToken = 'token';
  static const _kRelay = 'calls_force_relay';
  static const typingTtl = Duration(seconds: 5);

  final ApiFactory _apiFactory;
  final RealtimeFactory _realtimeFactory;
  final _uuid = const Uuid();

  SharedPreferences? _prefs;
  ApiClient? _api;
  Realtime? _rt;
  StreamSubscription<RealtimeEvent>? _eventsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;

  // ---- session ----
  bool initialized = false;
  String? serverUrl;
  User? me;

  /// Set after the first sign-in until the user picks a display name.
  bool needsName = false;

  /// Phone a code was requested for (between requestCode and verify).
  String? pendingPhone;

  /// Seconds until another code may be requested for [pendingPhone].
  int codeResendAfter = 60;

  ConnectionStatus connection = ConnectionStatus.disconnected;

  // ---- data ----
  final Map<int, User> users = {};
  List<Chat> chats = [];
  final Map<int, ChatMessages> _messages = {};
  final Map<int, Map<int, DateTime>> _typing = {};
  Timer? _typingTimer;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
  int? activeChatId;
  int _localIds = 0;

  // ---- calls ----
  ServerInfo? serverInfo;
  bool get callsEnabled => serverInfo?.calls ?? false;

  /// A call ringing for me right now (shown as a full-screen overlay).
  Call? incomingCall;

  /// The call I'm currently in.
  Call? activeCall;

  /// Live (ringing/active) calls by chat id — for the "join" banner.
  final Map<int, Call> liveCalls = {};

  /// Call history, newest first.
  List<Call> callHistory = [];

  /// Force TURN relay for calls (setting "Звонки только через сервер").
  bool get forceRelay => _prefs?.getBool(_kRelay) ?? false;
  Future<void> setForceRelay(bool v) async {
    await _prefs?.setBool(_kRelay, v);
    notifyListeners();
  }

  ApiClient? get api => _api;
  bool get isSignedIn => me != null && _api?.token != null;

  // =========================================================== session ====

  /// Restores a saved session. Call once at startup.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    serverUrl = _prefs!.getString(_kServer);
    final token = _prefs!.getString(_kToken);
    if (serverUrl != null && token != null) {
      _api = _apiFactory(serverUrl!, token);
      try {
        me = await _api!.me();
        needsName = me!.displayName.trim().isEmpty;
        await _afterSignIn();
      } on ApiException catch (e) {
        if (e.isUnauthorized) {
          await _clearSession();
        } else {
          // Offline: keep the token, retry via realtime reconnect.
          me = null;
        }
      }
    }
    initialized = true;
    notifyListeners();
  }

  /// Step 1: asks the server to send an SMS code.
  /// Returns seconds until another code can be requested.
  ///
  /// If a code was already sent to this phone and the resend cooldown is still
  /// running (e.g. the user went back from the code screen and tapped "Get
  /// code" again), this is not an error: the earlier code is still valid, so
  /// we move on to code entry with the remaining countdown.
  Future<int> requestCode(String server, String phone) async {
    serverUrl = ApiClient.normalizeBaseUrl(server);
    _api = _apiFactory(serverUrl!, null);
    int wait;
    try {
      wait = await _api!.requestCode(phone.trim());
    } on ApiException catch (e) {
      if (!e.codeSent) rethrow;
      wait = e.retryAfter ?? 60;
    }
    pendingPhone = phone.trim();
    codeResendAfter = wait > 0 ? wait : 60;
    await _prefs?.setString(_kServer, serverUrl!);
    notifyListeners();
    return wait;
  }

  /// Step 2: checks the code; on success the session is saved.
  Future<void> verify(String code) async {
    final api = _api;
    final phone = pendingPhone;
    if (api == null || phone == null) {
      throw const ApiException(400, 'Сначала запросите код');
    }
    final res = await api.verify(phone, code.trim());
    me = res.user;
    needsName = res.isNew || res.user.displayName.trim().isEmpty;
    pendingPhone = null;
    await _prefs?.setString(_kToken, res.token);
    await _afterSignIn();
    notifyListeners();
  }

  /// Back from the code screen to the phone screen.
  void cancelCode() {
    pendingPhone = null;
    notifyListeners();
  }

  /// Step 3 (new accounts): saves the display name.
  Future<void> setDisplayName(String name) async {
    me = await _api!.updateMe(displayName: name.trim());
    users[me!.id] = me!;
    needsName = false;
    notifyListeners();
  }

  Future<void> updateAvatar(String fileId) async {
    me = await _api!.updateMe(avatarFileId: fileId);
    users[me!.id] = me!;
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _api?.logout();
    } catch (_) {}
    await _clearSession();
    notifyListeners();
  }

  Future<void> _clearSession() async {
    await _rt?.dispose();
    await _eventsSub?.cancel();
    await _statusSub?.cancel();
    _rt = null;
    _api?.token = null;
    me = null;
    needsName = false;
    users.clear();
    chats = [];
    _messages.clear();
    _typing.clear();
    activeChatId = null;
    incomingCall = null;
    activeCall = null;
    liveCalls.clear();
    callHistory = [];
    serverInfo = null;
    await _prefs?.remove(_kToken);
  }

  Future<void> _afterSignIn() async {
    if (me != null) users[me!.id] = me!;
    await Future.wait([refreshUsers(), refreshChats(), _loadServerInfo()]);
    _startRealtime();
    if (callsEnabled) unawaited(refreshCalls().catchError((_) {}));
  }

  void _startRealtime() {
    final api = _api;
    if (api == null || _rt != null) return;
    final rt = _realtimeFactory(api);
    _rt = rt;
    var first = true;
    _eventsSub = rt.events.listen(applyEvent);
    _statusSub = rt.statusChanges.listen((s) {
      connection = s;
      if (s == ConnectionStatus.connected) {
        if (!first) _catchUp();
        first = false;
      }
      notifyListeners();
    });
    rt.start();
  }

  /// After a reconnect: reload chats and the newest page of the open chat.
  Future<void> _catchUp() async {
    await refreshChats();
    if (callsEnabled) await refreshCalls().catchError((_) {});
    final id = activeChatId;
    if (id != null) {
      try {
        final page = await _api!.messages(id);
        for (final m in page) {
          _upsert(m);
        }
        notifyListeners();
      } catch (_) {}
    }
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _clearSession();
        notifyListeners();
      } else {
        rethrow;
      }
    }
  }

  // ============================================================== users ===

  Future<void> refreshUsers() => _guard(() async {
        final list = await _api!.users();
        users
          ..clear()
          ..addEntries(list.map((u) => MapEntry(u.id, u)));
        notifyListeners();
      });

  String userName(int id) => users[id]?.displayName ?? '…';

  // ============================================================== chats ===

  Future<void> refreshChats() => _guard(() async {
        chats = await _api!.chats();
        _sortChats();
        notifyListeners();
        // Someone who joined after our sign-in may be in a chat already.
        if (chats.any((c) => c.memberIds.any((id) => !users.containsKey(id)))) {
          await refreshUsers();
        }
      });

  /// Refetches users at most once per few seconds when an unknown id shows up.
  DateTime _lastUserRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  void _ensureUser(int id) {
    if (users.containsKey(id) || _api == null) return;
    final now = DateTime.now();
    if (now.difference(_lastUserRefresh) < const Duration(seconds: 3)) return;
    _lastUserRefresh = now;
    refreshUsers();
  }

  Chat? chatById(int id) {
    for (final c in chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  int get totalUnread => chats.fold(0, (s, c) => s + c.unread);

  Future<Chat> openDirect(int userId) async {
    final chat = await _api!.createDirect(userId);
    _putChat(chat);
    return chat;
  }

  Future<Chat> createGroup(String title, List<int> memberIds) async {
    final chat = await _api!.createGroup(title, memberIds);
    _putChat(chat);
    return chat;
  }

  void _putChat(Chat chat) {
    final i = chats.indexWhere((c) => c.id == chat.id);
    if (i >= 0) {
      chats[i] = chat;
    } else {
      chats.add(chat);
    }
    _sortChats();
    notifyListeners();
  }

  void _replaceChat(Chat chat) {
    final i = chats.indexWhere((c) => c.id == chat.id);
    if (i >= 0) chats[i] = chat;
  }

  void _sortChats() {
    chats.sort((a, b) {
      final t = b.activityAt.compareTo(a.activityAt);
      return t != 0 ? t : b.id.compareTo(a.id);
    });
  }

  // =========================================================== messages ===

  ChatMessages messagesOf(int chatId) =>
      _messages.putIfAbsent(chatId, ChatMessages.new);

  /// Marks the chat as visible: loads messages and marks them read.
  Future<void> openChat(int chatId) async {
    activeChatId = chatId;
    final cm = messagesOf(chatId);
    if (!cm.loaded) await loadMore(chatId);
    await markRead(chatId);
  }

  void closeChat(int chatId) {
    if (activeChatId == chatId) activeChatId = null;
  }

  /// Loads the next older page.
  Future<void> loadMore(int chatId, {int limit = 50}) async {
    final cm = messagesOf(chatId);
    if (cm.loading || (cm.loaded && !cm.hasMore)) return;
    cm.loading = true;
    notifyListeners();
    try {
      await _guard(() async {
        final oldest = cm.items.where((m) => !m.isLocal).firstOrNull;
        final page = await _api!
            .messages(chatId, before: cm.loaded ? oldest?.id : null, limit: limit);
        for (final m in page) {
          _upsert(m);
        }
        cm.hasMore = page.length >= limit;
        cm.loaded = true;
      });
    } finally {
      cm.loading = false;
      notifyListeners();
    }
  }

  /// Inserts or replaces a server message. Returns true if it was not known.
  bool _upsert(Message m) {
    final list = messagesOf(m.chatId).items;
    final i = list.indexWhere((x) =>
        (!x.isLocal && x.id == m.id) ||
        (x.senderId == m.senderId && x.clientId == m.clientId));
    if (i >= 0) {
      final wasLocal = list[i].isLocal;
      list[i] = m;
      if (wasLocal) _sortMessages(list);
      return false;
    }
    list.add(m);
    _sortMessages(list);
    return true;
  }

  void _sortMessages(List<Message> list) {
    list.sort((a, b) {
      if (a.isLocal != b.isLocal) return a.isLocal ? 1 : -1;
      if (a.isLocal) return a.createdAt.compareTo(b.createdAt);
      return a.id.compareTo(b.id);
    });
  }

  void _setLocal(Message m) {
    final list = messagesOf(m.chatId).items;
    final i = list.indexWhere((x) => x.clientId == m.clientId && x.senderId == m.senderId);
    if (i >= 0) list[i] = m;
  }

  void _touchChat(Message m) {
    final chat = chatById(m.chatId);
    if (chat == null) return;
    _replaceChat(chat.copyWith(lastMessage: m));
    _sortChats();
  }

  Message _optimistic(int chatId,
      {required String kind, String text = '', FileInfo? file, int? replyToId}) {
    return Message(
      id: -(++_localIds),
      chatId: chatId,
      senderId: me!.id,
      clientId: _uuid.v4(),
      kind: kind,
      text: text,
      file: file,
      replyToId: replyToId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      state: SendState.pending,
    );
  }

  Future<void> sendText(int chatId, String text, {int? replyToId}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final m = _optimistic(chatId, kind: MessageKind.text, text: t, replyToId: replyToId);
    messagesOf(chatId).items.add(m);
    _touchChat(m);
    notifyListeners();
    await _deliver(m);
  }

  /// Uploads [bytes] and sends them as image/video/file/voice.
  Future<void> sendFile(
    int chatId,
    Uint8List bytes, {
    required String filename,
    required String mime,
    String caption = '',
    bool voice = false,
    int? width,
    int? height,
    int? durationMs,
    int? replyToId,
  }) async {
    final local = FileInfo(
      id: '',
      name: filename,
      mime: mime,
      size: bytes.length,
      width: width ?? 0,
      height: height ?? 0,
      durationMs: durationMs ?? 0,
    );
    final m = _optimistic(chatId,
        kind: MessageKind.forMime(mime, voice: voice),
        text: caption.trim(),
        file: local,
        replyToId: replyToId);
    messagesOf(chatId).items.add(m);
    _pendingUploads[m.clientId] = bytes;
    _touchChat(m);
    notifyListeners();
    await _deliver(m);
  }

  final Map<String, Uint8List> _pendingUploads = {};

  /// Bytes of a file being uploaded (for local previews).
  Uint8List? pendingBytes(Message m) => _pendingUploads[m.clientId];

  Future<void> _deliver(Message m) async {
    try {
      String? fileId;
      if (m.file != null) {
        fileId = m.file!.id;
        if (fileId.isEmpty) {
          final f = m.file!;
          final uploaded = await _api!.uploadFile(
            _pendingUploads[m.clientId]!,
            filename: f.name,
            mime: f.mime,
            width: f.width > 0 ? f.width : null,
            height: f.height > 0 ? f.height : null,
            durationMs: f.durationMs > 0 ? f.durationMs : null,
          );
          fileId = uploaded.id;
        }
      }
      final sent = await _api!.sendMessage(
        m.chatId,
        clientId: m.clientId,
        text: m.text,
        fileId: fileId,
        kind: m.kind,
        replyToId: m.replyToId,
      );
      _pendingUploads.remove(m.clientId);
      _upsert(sent);
      final chat = chatById(sent.chatId);
      if (chat != null) {
        final last = chat.lastMessage;
        if (last == null || last.isLocal || sent.id >= last.id) {
          _replaceChat(chat.copyWith(lastMessage: sent));
          _sortChats();
        }
      }
    } catch (_) {
      _setLocal(m.copyWith(state: SendState.failed));
    }
    notifyListeners();
  }

  Future<void> retry(Message m) async {
    if (m.state != SendState.failed) return;
    final pending = m.copyWith(state: SendState.pending);
    _setLocal(pending);
    notifyListeners();
    await _deliver(pending);
  }

  /// Removes a failed local message, or deletes a sent one on the server.
  Future<void> deleteMessage(Message m) async {
    if (m.isLocal) {
      messagesOf(m.chatId).items.removeWhere((x) => x.clientId == m.clientId);
      _pendingUploads.remove(m.clientId);
      notifyListeners();
      return;
    }
    await _api!.deleteMessage(m.id);
    _markDeleted(m.chatId, m.id);
    notifyListeners();
  }

  void _markDeleted(int chatId, int id) {
    final list = messagesOf(chatId).items;
    final i = list.indexWhere((x) => !x.isLocal && x.id == id);
    if (i >= 0) list[i] = list[i].copyWith(deleted: true, text: '');
    final chat = chatById(chatId);
    if (chat != null && chat.lastMessage?.id == id) {
      _replaceChat(chat.copyWith(lastMessage: chat.lastMessage!.copyWith(deleted: true, text: '')));
    }
  }

  /// Marks everything loaded in the chat as read.
  Future<void> markRead(int chatId) async {
    final chat = chatById(chatId);
    if (chat == null) return;
    final lastServer = messagesOf(chatId).items.where((m) => !m.isLocal).lastOrNull;
    final upTo = lastServer?.id ?? chat.lastMessage?.id ?? 0;
    if (upTo <= chat.lastReadId && chat.unread == 0) return;
    _replaceChat(chat.copyWith(lastReadId: upTo, unread: 0));
    notifyListeners();
    if (upTo > 0) {
      try {
        await _api!.markRead(chatId, upTo);
      } catch (_) {}
    }
  }

  // ============================================================= typing ===

  /// Call on every keystroke; throttled to one event per 3 s.
  void typing(int chatId) {
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) < const Duration(seconds: 3)) return;
    _lastTypingSent = now;
    _rt?.sendTyping(chatId);
  }

  /// Users currently typing in [chatId] (excluding me).
  List<int> typingIn(int chatId) {
    final now = DateTime.now();
    final m = _typing[chatId];
    if (m == null) return const [];
    return m.entries
        .where((e) => now.difference(e.value) < typingTtl)
        .map((e) => e.key)
        .toList();
  }

  void _scheduleTypingCleanup() {
    _typingTimer?.cancel();
    _typingTimer = Timer(typingTtl, () {
      final now = DateTime.now();
      for (final m in _typing.values) {
        m.removeWhere((_, t) => now.difference(t) >= typingTtl);
      }
      _typing.removeWhere((_, m) => m.isEmpty);
      notifyListeners();
      if (_typing.isNotEmpty) _scheduleTypingCleanup();
    });
  }

  // ============================================================= events ===

  @visibleForTesting
  void debugSeed({required User me, List<User> users = const [], List<Chat> chats = const []}) {
    this.me = me;
    this.users
      ..clear()
      ..[me.id] = me
      ..addEntries(users.map((u) => MapEntry(u.id, u)));
    this.chats = List.of(chats);
    _sortChats();
  }

  /// Applies a realtime event from the server.
  void applyEvent(RealtimeEvent e) {
    switch (e.type) {
      case RealtimeEvent.messageNew:
        _onMessage(Message.fromJson(e.data));
      case RealtimeEvent.messageDeleted:
        _markDeleted(_toInt(e.data['chat_id']), _toInt(e.data['id']));
      case RealtimeEvent.chatNew:
        refreshChats();
        return;
      case RealtimeEvent.chatRead:
        _onRead(_toInt(e.data['chat_id']), _toInt(e.data['user_id']),
            _toInt(e.data['message_id']));
      case RealtimeEvent.callRing:
        _onCallRing(Call.fromJson(e.data));
      case RealtimeEvent.callUpdated:
        _onCallUpdated(Call.fromJson(e.data));
      case RealtimeEvent.callEnded:
        _onCallEnded(Call.fromJson(e.data));
      case RealtimeEvent.typing:
        final chatId = _toInt(e.data['chat_id']);
        final userId = _toInt(e.data['user_id']);
        if (userId == me?.id) return;
        _typing.putIfAbsent(chatId, () => {})[userId] = DateTime.now();
        _scheduleTypingCleanup();
      default:
        return;
    }
    notifyListeners();
  }

  // ============================================================== calls ===

  Future<void> _loadServerInfo() async {
    try {
      serverInfo = await _api!.info();
    } catch (_) {}
  }

  Future<void> refreshCalls() => _guard(() async {
        callHistory = await _api!.calls();
        liveCalls
          ..clear()
          ..addEntries(callHistory.where((c) => c.isLive).map((c) => MapEntry(c.chatId, c)));
        _surfaceRingingCall();
        notifyListeners();
      });

  /// Calls this device already answered, declined or dismissed, so a later
  /// refresh does not bring their incoming screen back.
  final Set<int> _handledIncoming = {};

  /// The incoming screen is normally raised by the realtime "call ringing"
  /// event. If that event was missed — iOS suspends the app and drops the
  /// WebSocket while it is in the background or the screen is locked — the
  /// call still shows up in the list fetched on reconnect/resume. Ring for it
  /// then, so the person can still answer.
  void _surfaceRingingCall() {
    if (incomingCall != null || activeCall != null) return;
    final myId = me?.id;
    if (myId == null) return;
    for (final c in callHistory) {
      if (c.state == CallState.ringing &&
          c.initiatorId != myId &&
          !c.participantIds.contains(myId) &&
          !_handledIncoming.contains(c.id)) {
        incomingCall = c;
        return;
      }
    }
  }

  /// The app came back to the foreground: reconnect right away (instead of
  /// waiting out the reconnect backoff) and look for a call that is ringing.
  void onAppResumed() {
    if (!isSignedIn) return;
    _rt?.reconnectNow();
    if (callsEnabled) unawaited(refreshCalls().catchError((_) {}));
  }

  void _upsertHistory(Call c) {
    final i = callHistory.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      callHistory[i] = c;
    } else {
      callHistory.insert(0, c);
    }
    callHistory.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void _onCallRing(Call c) {
    liveCalls[c.chatId] = c;
    _upsertHistory(c);
    if (c.initiatorId == me?.id) return; // my own outgoing call
    if (activeCall?.id == c.id) return;
    // Busy in another call: don't interrupt; it stays in the join banner.
    if (activeCall == null) incomingCall = c;
  }

  void _onCallUpdated(Call c) {
    if (c.isLive) {
      liveCalls[c.chatId] = c;
    } else {
      liveCalls.remove(c.chatId);
    }
    _upsertHistory(c);
    if (activeCall?.id == c.id) activeCall = c;
    final inc = incomingCall;
    if (inc != null && inc.id == c.id) {
      final answeredByMe = c.participantIds.contains(me?.id);
      final directAnswered = chatById(c.chatId)?.isGroup != true &&
          c.state == CallState.active;
      if (!c.isLive || answeredByMe || directAnswered) incomingCall = null;
    }
  }

  void _onCallEnded(Call c) {
    liveCalls.remove(c.chatId);
    _upsertHistory(c);
    if (incomingCall?.id == c.id) incomingCall = null;
    if (activeCall?.id == c.id) activeCall = c; // UI sees !isLive and closes
  }

  /// Starts (or joins an already running) call in [chatId].
  Future<CallJoin> startCall(int chatId, {required bool video}) async {
    final j = await _api!.startCall(chatId, video: video);
    activeCall = j.call;
    liveCalls[chatId] = j.call;
    _upsertHistory(j.call);
    notifyListeners();
    return j;
  }

  /// Accepts a ringing or joins an active call.
  Future<CallJoin> joinCall(Call c) async {
    _handledIncoming.add(c.id);
    final j = await _api!.joinCall(c.id);
    activeCall = j.call;
    if (incomingCall?.id == c.id) incomingCall = null;
    liveCalls[j.call.chatId] = j.call;
    _upsertHistory(j.call);
    notifyListeners();
    return j;
  }

  /// Hides the incoming overlay without telling the server.
  void dismissIncoming() {
    final c = incomingCall;
    if (c == null) return;
    _handledIncoming.add(c.id);
    incomingCall = null;
    notifyListeners();
  }

  Future<void> declineIncoming() async {
    final c = incomingCall;
    if (c == null) return;
    _handledIncoming.add(c.id);
    incomingCall = null;
    notifyListeners();
    try {
      await _api!.declineCall(c.id);
    } catch (_) {}
  }

  /// Leaves the current call (best effort).
  Future<void> leaveCall() async {
    final c = activeCall;
    activeCall = null;
    notifyListeners();
    if (c == null) return;
    try {
      await _api!.leaveCall(c.id);
    } catch (_) {}
  }

  static int _toInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  void _onMessage(Message m) {
    _ensureUser(m.senderId);
    final chat = chatById(m.chatId);
    final cm = _messages[m.chatId];
    final knownInList = cm != null &&
        cm.items.any((x) => (!x.isLocal && x.id == m.id));
    final last = chat?.lastMessage;
    final newerThanLast = last == null || last.isLocal || m.id > last.id;
    final fresh = !knownInList && newerThanLast;

    if (cm != null && (cm.loaded || cm.items.isNotEmpty)) {
      _upsert(m);
    }
    _typing[m.chatId]?.remove(m.senderId);

    if (chat == null) {
      refreshChats();
      return;
    }
    var updated = chat;
    if (newerThanLast) {
      updated = updated.copyWith(lastMessage: m);
    }
    final mine = m.senderId == me?.id;
    if (fresh && !mine) {
      if (activeChatId == m.chatId) {
        _replaceChat(updated);
        _sortChats();
        markRead(m.chatId);
        return;
      }
      updated = updated.copyWith(unread: updated.unread + 1);
    }
    _replaceChat(updated);
    _sortChats();
  }

  void _onRead(int chatId, int userId, int messageId) {
    final chat = chatById(chatId);
    if (chat == null) return;
    if (userId == me?.id) {
      // Read on another device of mine.
      if (messageId <= chat.lastReadId) return;
      final cm = _messages[chatId];
      int unread;
      if (cm != null && cm.loaded) {
        unread = cm.items
            .where((m) => !m.isLocal && m.id > messageId && m.senderId != me?.id)
            .length;
      } else {
        unread = (chat.lastMessage?.id ?? 0) <= messageId ? 0 : chat.unread;
      }
      _replaceChat(chat.copyWith(lastReadId: messageId, unread: unread));
    } else if (messageId > chat.othersReadId) {
      _replaceChat(chat.copyWith(othersReadId: messageId));
    }
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _eventsSub?.cancel();
    _statusSub?.cancel();
    _rt?.dispose();
    super.dispose();
  }
}
