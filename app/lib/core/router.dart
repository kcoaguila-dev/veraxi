import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/features/auth/views/login_screen.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';
import 'package:veraxi_app/features/chat/views/shared_chat_screen.dart';
import 'package:veraxi_app/features/control_panel/views/control_panel_screen.dart';
import 'package:veraxi_app/features/docs/views/docs_screen.dart';
import 'package:veraxi_app/features/landing/views/landing_screen.dart';
import 'package:veraxi_app/core/local_mode_storage.dart';


final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

const bool isAuthEnabled =
    bool.fromEnvironment('AUTH_ENABLED', defaultValue: true);

const bool isSelfHosted =
    bool.fromEnvironment('IS_SELF_HOSTED', defaultValue: true);

bool? mockIsAuth;

final goRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: isSelfHosted ? '/login' : '/',
  redirect: (context, state) async {
    bool isSessionValid = false;
    try {
      if (isAuthEnabled) {
        isSessionValid = Supabase.instance.client.auth.currentSession != null;
      }
    } catch (e) {
      // Supabase is not initialized yet
      isSessionValid = false;
    }

    final isLocalMode = await LocalModeStorage().isLocalMode();
    final isAuth = mockIsAuth ?? (!isAuthEnabled || isSessionValid || isLocalMode);

    final isLoggingIn = state.matchedLocation == '/login';
    final isLanding = state.matchedLocation == '/';
    final isDocs = state.matchedLocation == '/docs';
    final isShared = state.matchedLocation.startsWith('/share');

    // If self-hosted and user tries to access landing page, force to login
    if (isSelfHosted && isLanding) {
      return '/login';
    }

    if (!isAuth && !isLoggingIn && !isLanding && !isDocs && !isShared) {
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
      builder: (BuildContext context, GoRouterState state) =>
          const LandingScreen(),
    ),
    GoRoute(
      path: '/docs',
      builder: (BuildContext context, GoRouterState state) =>
          const DocsScreen(),
    ),
    GoRoute(
      path: '/share/:shareId',
      builder: (BuildContext context, GoRouterState state) {
        final shareId = state.pathParameters['shareId']!;
        return SharedChatScreen(shareId: shareId);
      },
    ),
    GoRoute(
      path: '/login',
      builder: (BuildContext context, GoRouterState state) =>
          const LoginScreen(),
    ),
    GoRoute(
      path: '/chat',
      builder: (BuildContext context, GoRouterState state) =>
          const ChatScreen(),
    ),
    GoRoute(
      path: '/admin',
      builder: (BuildContext context, GoRouterState state) =>
          const ControlPanelScreen(),
    ),
  ],
);
