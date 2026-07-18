import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme.dart';

import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:veraxi_app/core/router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://placeholder.supabase.co'),
    publishableKey: const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: 'placeholder'),
  );

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

class VeraxiApp extends StatelessWidget {
  const VeraxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Veraxi',
      theme: AppTheme.darkTheme,
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

    return Scaffold(
      body: Row(
        children: [
          if (isWideScreen)
            NavigationRail(
              backgroundColor: AppTheme.background,
              indicatorColor: AppTheme.primary.withAlpha(51),
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _onItemTapped,
              selectedIconTheme: const IconThemeData(color: AppTheme.primary),
              unselectedIconTheme: const IconThemeData(color: AppTheme.textSecondary),
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
            const VerticalDivider(thickness: 1, width: 1, color: AppTheme.surfaceHighlight),
          Expanded(
            child: navigationShell,
          ),
        ],
      ),
      bottomNavigationBar: isWideScreen
          ? null
          : BottomNavigationBar(
              backgroundColor: AppTheme.background,
              selectedItemColor: AppTheme.primary,
              unselectedItemColor: AppTheme.textSecondary,
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
