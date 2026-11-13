import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/realtime.dart';
import '../../data/store.dart';
import '../calls/calls_screen.dart';
import '../chat/chat_screen.dart';
import '../chats/chat_list.dart';
import '../settings/settings_screen.dart';
import '../theme.dart';

enum _Pane { chat, calls, settings }

/// Signed-in shell: tabs on phones, two panes on wide screens (Web.dc.html).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int? _selectedChat;
  _Pane _pane = _Pane.chat;

  void _openNarrow(int chatId) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
  }

  void _openWide(int chatId) => setState(() {
    _selectedChat = chatId;
    _pane = _Pane.chat;
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) =>
          c.maxWidth < Fg.wideBreakpoint ? _narrow(context) : _wide(context),
    );
  }

  Widget _narrow(BuildContext context) {
    final unread = context.select<AppStore, int>((s) => s.totalUnread);
    return Scaffold(
      // Top inset handled once here; inner screens keep their own AppBars.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const ConnectionBanner(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  ChatListView(onOpen: _openNarrow),
                  const CallsScreen(),
                  const SettingsScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        height: 64,
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 99 ? '99+' : '$unread'),
              child: const Icon(Icons.chat_bubble_outline),
            ),
            selectedIcon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 99 ? '99+' : '$unread'),
              child: const Icon(Icons.chat_bubble),
            ),
            label: 'Чаты',
          ),
          const NavigationDestination(
            icon: Icon(Icons.call_outlined),
            selectedIcon: Icon(Icons.call),
            label: 'Звонки',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Настройки',
          ),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget paneButton(
      _Pane pane,
      IconData icon,
      IconData activeIcon,
      String label,
    ) {
      final active = _pane == pane;
      return IconButton(
        tooltip: label,
        isSelected: active,
        color: active ? scheme.primary : context.secondaryText,
        onPressed: () => setState(() => _pane = active ? _Pane.chat : pane),
        icon: Icon(active ? activeIcon : icon),
      );
    }

    final Widget right;
    switch (_pane) {
      case _Pane.calls:
        right = const CallsScreen();
      case _Pane.settings:
        right = const SettingsScreen();
      case _Pane.chat:
        right = _selectedChat == null
            ? const _NoChatSelected()
            : ChatScreen(
                key: ValueKey(_selectedChat),
                chatId: _selectedChat!,
                embedded: true,
              );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 360,
              child: Column(
                children: [
                  const ConnectionBanner(),
                  Expanded(
                    child: ChatListView(
                      onOpen: _openWide,
                      selectedChatId: _pane == _Pane.chat
                          ? _selectedChat
                          : null,
                      extraActions: [
                        paneButton(
                          _Pane.calls,
                          Icons.call_outlined,
                          Icons.call,
                          'Звонки',
                        ),
                        paneButton(
                          _Pane.settings,
                          Icons.settings_outlined,
                          Icons.settings,
                          'Настройки',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: right),
          ],
        ),
      ),
    );
  }
}

class _NoChatSelected extends StatelessWidget {
  const _NoChatSelected();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.chatBg,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: context.isDark ? 0.35 : 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            'Выберите чат',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: context.isDark ? Colors.white : Fg.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// Slim banner shown while the realtime connection is down.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.select<AppStore, ConnectionStatus>(
      (s) => s.connection,
    );
    final visible = status != ConnectionStatus.connected;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              color: context.isDark
                  ? scheme.primary.withValues(alpha: 0.18)
                  : Fg.accentTint,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Соединение…',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
