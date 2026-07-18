import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/features/auth/views/login_screen.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';
import 'package:veraxi_app/features/control_panel/views/control_panel_screen.dart';
import 'package:veraxi_app/features/landing/views/landing_screen.dart';
import 'package:veraxi_app/main.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

final goRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/',
  redirect: (context, state) {
    final session = Supabase.instance.client.auth.currentSession;
    final isAuth = session != null;
    
    final isLoggingIn = state.matchedLocation == '/login';
    final isLanding = state.matchedLocation == '/';

    if (!isAuth && !isLoggingIn && !isLanding) {
      return '/login';
    }

    if (isAuth && (isLoggingIn || isLanding)) {
      return '/chat';
    }

    return null;
  },
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      builder: (BuildContext context, GoRouterState state) => const LandingScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (BuildContext context, GoRouterState state) => const LoginScreen(),
    ),
    StatefulShellRoute.indexedStack(
      builder: (BuildContext context, GoRouterState state, StatefulNavigationShell navigationShell) {
        return ScaffoldWithNavBar(navigationShell: navigationShell);
      },
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/chat',
              builder: (BuildContext context, GoRouterState state) => const ChatScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/admin',
              builder: (BuildContext context, GoRouterState state) => const ControlPanelScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);
