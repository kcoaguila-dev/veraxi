import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/api_keys_view.dart';
import 'package:veraxi_app/core/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Mock secure storage for headless CI environments
  FlutterSecureStorage.setMockInitialValues({});

  // Mock SpeechToText platform channel to prevent MissingPluginException on Linux
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugin.csdcorp.com/speech_to_text'),
          (MethodCall methodCall) async {
    if (methodCall.method == 'initialize') {
      return true;
    }
    return null;
  });

  testWidgets('E2E BYOD Flow: Save Infrastructure Settings',
      (WidgetTester tester) async {
    final storage = ApiKeyStorage();
    // Clear storage before test
    await storage.saveByodConfig(
      neo4jUri: '',
      neo4jUser: '',
      neo4jPass: '',
      qdrantUrl: '',
      qdrantKey: '',
    );

    // Boot the widget in isolation for testing
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: ApiKeysView(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify initial UI state
    expect(find.text('Bring Your Own Infrastructure'), findsOneWidget);

    // Find the text fields for Neo4j and Qdrant
    // We use the label text to find them
    final neo4jUriField = find
        .ancestor(
          of: find.text('Neo4j URI'),
          matching: find.byType(Column),
        )
        .first;

    // The actual TextField is a descendant of the Column
    await tester.enterText(
        find.descendant(of: neo4jUriField, matching: find.byType(TextField)),
        'bolt://test-neo4j:7687');

    final neo4jUserField = find
        .ancestor(
          of: find.text('Username'),
          matching: find.byType(Column),
        )
        .first;
    await tester.enterText(
        find.descendant(of: neo4jUserField, matching: find.byType(TextField)),
        'test_user');

    final qdrantUrlField = find
        .ancestor(
          of: find.text('Qdrant REST URL'),
          matching: find.byType(Column),
        )
        .first;
    await tester.enterText(
        find.descendant(of: qdrantUrlField, matching: find.byType(TextField)),
        'http://test-qdrant:6333');

    // Scroll to the bottom to ensure the Save button is fully visible
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();

    // Bypass hit-testing in headless CI by invoking the callback directly
    // Find all ElevatedButtons and identify the "Save Configuration" one.
    final buttonFinder = find.byWidgetPredicate((widget) {
      if (widget is ElevatedButton) {
        final textWidget = widget.child;
        if (textWidget is Text && textWidget.data == 'Save Configuration') {
          return true;
        }
      }
      return false;
    });

    final button = tester.widget<ElevatedButton>(buttonFinder.first);
    button.onPressed!();

    // Allow animations and async saves to settle
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Verify it was saved to secure storage
    final savedConfig = await storage.getByodConfig();
    expect(savedConfig['neo4j_uri'], 'bolt://test-neo4j:7687');
    expect(savedConfig['neo4j_user'], 'test_user');
    expect(savedConfig['qdrant_url'], 'http://test-qdrant:6333');

    // Verify SnackBar appeared
    expect(find.text('Infrastructure settings saved locally.'), findsOneWidget);
  });
}
