import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/settings/views/widgets/settings_dialog.dart';
import 'package:veraxi_app/features/auth/view_models/auth_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Mock AuthViewModel for the SettingsDialog which might need user data
class MockAuthViewModel extends StateNotifier<AsyncValue<User?>> implements AuthViewModel {
  MockAuthViewModel() : super(AsyncData(User(
    id: 'test_user_id',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: DateTime.now().toIso8601String(),
  )));

  @override
  Future<void> signInWithOAuth(OAuthProvider provider) async {}
  @override
  Future<void> signIn(String email, String password) async {}
  @override
  Future<void> signUp(String email, String password) async {}
  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets('SettingsDialog shows Data & Privacy tab and GDPR buttons', (WidgetTester tester) async {
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
          home: Scaffold(
            body: SettingsDialog(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Data & Privacy tab exists
    final dataTab = find.text('Data & Privacy');
    expect(dataTab, findsWidgets);
    
    // Tap the Data & Privacy tab
    await tester.tap(dataTab.first);
    await tester.pumpAndSettle();

    // Verify Export Data button exists
    final exportText = find.text('Export data');
    expect(exportText, findsOneWidget);

    // Verify Delete Account button exists
    final deleteText = find.text('Delete account & data');
    expect(deleteText, findsOneWidget);
  });
}
