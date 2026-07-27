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

  const bool isAuthEnabled = false;
  
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

  Widget _buildSidebarIcon(IconData icon, int index, int currentIndex) {
    final isSelected = index == currentIndex;
    return GestureDetector(
      onTap: () {
        if (index != -1) _onItemTapped(index);
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: isSelected
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF3B82F6), width: 1.5),
              )
            : null,
        child: Icon(
          icon,
          color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFFB4B4B4),
          size: 20,
        ),
      ),
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
            Container(
              width: 64,
              color: const Color(0xFF171717),
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  const Icon(Icons.grid_view, color: Color(0xFFB4B4B4), size: 24),
                  const SizedBox(height: 30),
                  
                  _buildSidebarIcon(Icons.chat_bubble_outline, 0, navigationShell.currentIndex),
                  const SizedBox(height: 16),
                  _buildSidebarIcon(Icons.description_outlined, -1, navigationShell.currentIndex),
                  const SizedBox(height: 16),
                  _buildSidebarIcon(Icons.settings_outlined, 1, navigationShell.currentIndex),
                  const SizedBox(height: 16),
                  _buildSidebarIcon(Icons.terminal_outlined, -1, navigationShell.currentIndex),
                  const SizedBox(height: 16),
                  _buildSidebarIcon(Icons.bookmark_border, -1, navigationShell.currentIndex),
                  
                  const Spacer(),
                  
                  Icon(Icons.change_history, color: const Color(0xFF3B82F6).withValues(alpha: 0.8), size: 28),
                  const SizedBox(height: 24),
                ],
              ),
            ),
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
