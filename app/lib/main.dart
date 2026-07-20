import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/core/theme_provider.dart';

import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:veraxi_app/core/router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const bool isAuthEnabled = bool.fromEnvironment('AUTH_ENABLED', defaultValue: true);
  
  if (isAuthEnabled) {
    await Supabase.initialize(
      url: const String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://placeholder.supabase.co'),
      publishableKey: const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: 'placeholder'),
    );
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = const String.fromEnvironment('SENTRY_DSN', defaultValue: '');
      options.tracesSampleRate = 1.0;
    },
    appRunner: () => runApp(
      const ProviderScope(
        child: VeraxiApp(),
      ),
    ),
  );
}

class VeraxiApp extends ConsumerWidget {
  const VeraxiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);

    return MaterialApp.router(
      title: 'Veraxi',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: goRouter,
      debugShowCheckedModeBanner: false,
    );
  }
}

class ScaffoldWithNavBar extends StatelessWidget {
  const ScaffoldWithNavBar({
    required this.navigationShell,
    super.key,
  });

  final StatefulNavigationShell navigationShell;

  void _onItemTapped(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isWideScreen = MediaQuery.of(context).size.width >= 600;

    final theme = Theme.of(context);

    return Scaffold(
      body: Row(
        children: [
          if (isWideScreen)
            NavigationRail(
              backgroundColor: theme.scaffoldBackgroundColor,
              indicatorColor: theme.colorScheme.primary.withValues(alpha: 0.2),
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _onItemTapped,
              selectedIconTheme: IconThemeData(color: theme.colorScheme.primary),
              unselectedIconTheme: IconThemeData(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
              destinations: const <NavigationRailDestination>[
                NavigationRailDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: Text('Chat'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.admin_panel_settings_outlined),
                  selectedIcon: Icon(Icons.admin_panel_settings),
                  label: Text('Control Panel'),
                ),
              ],
            ),
          if (isWideScreen)
            const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: navigationShell,
          ),
        ],
      ),
      bottomNavigationBar: isWideScreen
          ? null
          : BottomNavigationBar(
              selectedItemColor: theme.colorScheme.primary,
              unselectedItemColor: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              items: const <BottomNavigationBarItem>[
                BottomNavigationBarItem(
                  icon: Icon(Icons.chat_bubble_outline),
                  activeIcon: Icon(Icons.chat_bubble),
                  label: 'Chat',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.admin_panel_settings_outlined),
                  activeIcon: Icon(Icons.admin_panel_settings),
                  label: 'Control Panel',
                ),
              ],
              currentIndex: navigationShell.currentIndex,
              onTap: _onItemTapped,
            ),
    );
  }
}
