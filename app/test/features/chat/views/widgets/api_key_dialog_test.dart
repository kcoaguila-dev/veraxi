import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('ApiKeyDialog saves key on Submit', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(child: ApiKeyDialog(providerName: 'Gemini')),
      ),
    ));

    // Wait for the dialog to fully load (and for getGeminiKey() Future to resolve)
    await tester.pumpAndSettle();

    // Verify dialog shows
    expect(find.text('Set API Key for Gemini'), findsOneWidget);

    // Enter a dummy API key
    await tester.enterText(find.byType(TextField), 'dummy_gemini_key_123');
    await tester.pump();

    // Tap Submit
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    // Verify it was saved to storage
    final savedKey = await ApiKeyStorage().getGeminiKey();
    expect(savedKey, 'dummy_gemini_key_123');
  });
}
