import 'package:flutter/material.dart';

import 'models/memo.dart';
import 'screens/edit_screen.dart';
import 'screens/home_screen.dart';
import 'screens/pair_screen.dart';
import 'screens/settings_screen.dart';
import 'services/identity.dart';
import 'services/store.dart';
import 'services/sync_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.open();
  final identity = IdentityService(store);
  await identity.ensureIdentity();
  final syncClient = SyncClient(store: store, identity: identity);
  runApp(MemoLinkApp(
    store: store,
    identity: identity,
    syncClient: syncClient,
  ));
}

class MemoLinkApp extends StatelessWidget {
  const MemoLinkApp({
    super.key,
    required this.store,
    required this.identity,
    required this.syncClient,
  });

  final Store store;
  final IdentityService identity;
  final SyncClient syncClient;

  @override
  Widget build(BuildContext context) {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8B7355),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'MemoLink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: base.copyWith(
          surface: const Color(0xFFF5F0E8),
          primary: const Color(0xFF5C4A32),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F0E8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F0E8),
          foregroundColor: Color(0xFF2B2A28),
          elevation: 0,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF2B2A28),
          foregroundColor: Color(0xFFF5F0E8),
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(store: store, syncClient: syncClient),
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/pair':
            return MaterialPageRoute(
              builder: (_) => PairScreen(store: store, syncClient: syncClient),
            );
          case '/settings':
            return MaterialPageRoute(
              builder: (_) => SettingsScreen(
                store: store,
                identity: identity,
                syncClient: syncClient,
              ),
            );
          case '/edit':
            final memo = settings.arguments is Memo ? settings.arguments as Memo : null;
            return MaterialPageRoute(
              builder: (_) => EditScreen(
                store: store,
                identity: identity,
                syncClient: syncClient,
                memo: memo,
              ),
            );
          default:
            return null;
        }
      },
    );
  }
}
