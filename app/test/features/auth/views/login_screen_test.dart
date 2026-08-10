import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/auth/views/login_screen.dart';
import 'package:veraxi_app/features/auth/view_models/auth_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Mock AuthViewModel to capture interactions
class MockAuthViewModel extends StateNotifier<AsyncValue<User?>> implements AuthViewModel {
  MockAuthViewModel() : super(const AsyncData(null));

  bool googleCalled = false;
  bool githubCalled = false;

  @override
  Future<void> signInWithOAuth(OAuthProvider provider) async {
    if (provider == OAuthProvider.google) {
      googleCalled = true;
    } else if (provider == OAuthProvider.github) {
      githubCalled = true;
    }
  }

  @override
  Future<void> signIn(String email, String password) async {}
  @override
  Future<void> signUp(String email, String password) async {}
  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets('LoginScreen OAuth buttons trigger AuthViewModel methods', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());

    final mockAuthViewModel = MockAuthViewModel();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authViewModelProvider.overrideWith((ref) => mockAuthViewModel),
        ],
        child: const MaterialApp(
          home: LoginScreen(),
        ),
      ),
    );

    // Allow animations to finish
    await tester.pumpAndSettle();

    // Find and tap the Google button
    final googleButton = find.text('Continue with Google');
    expect(googleButton, findsOneWidget);
    await tester.ensureVisible(googleButton);
    await tester.tap(googleButton);
    await tester.pump();
    
    expect(mockAuthViewModel.googleCalled, isTrue, reason: "Google sign-in was not triggered");

    // Find and tap the GitHub button
    final githubButton = find.text('Continue with GitHub');
    expect(githubButton, findsOneWidget);
    await tester.ensureVisible(githubButton);
    await tester.tap(githubButton);
    await tester.pump();

    expect(mockAuthViewModel.githubCalled, isTrue, reason: "GitHub sign-in was not triggered");
  });
}
