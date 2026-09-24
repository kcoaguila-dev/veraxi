import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('end-to-end test', () {
    testWidgets('verify app startup and smoke test', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // The app initialization takes some time because of Supabase.
      try {
        await Supabase.initialize(
          url: const String.fromEnvironment(
            'SUPABASE_URL',
            defaultValue: 'https://zjtqrwxyoswzlvtetjzi.supabase.co',
          ),
          publishableKey: const String.fromEnvironment(
            'SUPABASE_ANON_KEY',
            defaultValue: 'sb_publishable_6j3NNIfgI5V209p9QGL-DA_GyEsz9jI',
          ),
        );
      } catch (e) {
        // Ignore if already initialized
      }

      runApp(const ProviderScope(child: app.VeraxiApp()));

      // Wait for the app to fully load and settle.
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Check if the chat input is present.
      expect(find.byType(TextField), findsWidgets);
    });
  });
}
