import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'data/store.dart';
import 'ui/auth/code_screen.dart';
import 'ui/auth/login_screen.dart';
import 'ui/auth/name_screen.dart';
import 'ui/call/call_controller.dart';
import 'ui/call/incoming_call.dart';
import 'ui/home/home_screen.dart';
import 'ui/theme.dart';

/// Entry point of the tiny engine that iOS starts only to host CallKit when a
/// call's VoIP push arrives before the app's UI (ios/Runner/AppDelegate.swift).
/// The real app starts in [main]; this one does nothing.
@pragma('vm:entry-point')
void callkitHostMain() {}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppStore.forDevice()..init(),
      child: const FamilygramApp(),
    ),
  );
}

class FamilygramApp extends StatelessWidget {
  const FamilygramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Familygram',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appMessengerKey,
      builder: (context, child) =>
          IncomingCallLayer(child: child ?? const SizedBox.shrink()),
      home: const RootGate(),
    );
  }
}

/// Picks the top-level screen from the session state.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  // On return to the foreground, reconnect at once and catch a call that
  // started ringing while iOS had the app suspended.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () => context.read<AppStore>().onAppResumed(),
  );

  late final AppStore _store = context.read<AppStore>();

  @override
  void initState() {
    super.initState();
    _lifecycle; // create the listener
    // Answered on the system call screen: join immediately (see the store).
    _store.onCallKitAccept = (id) {
      if (mounted) CallController.acceptFromCallKit(context, id);
    };
    final pending = _store.takeCallKitAcceptRequest();
    if (pending != null) _store.onCallKitAccept!(pending);
  }

  @override
  void dispose() {
    _store.onCallKitAccept = null;
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final Widget page;
    if (!store.initialized) {
      page = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (!store.isSignedIn) {
      page = store.pendingPhone != null
          ? CodeScreen(resendAfter: store.codeResendAfter)
          : const LoginScreen();
    } else if (store.needsName) {
      page = const NameScreen();
    } else {
      page = const HomeScreen();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: KeyedSubtree(key: ValueKey(page.runtimeType), child: page),
    );
  }
}
