import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/api_keys_view.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E2E BYOD Flow: Save Infrastructure Settings', (WidgetTester tester) async {
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
      const MaterialApp(
        home: Scaffold(
          body: ApiKeysView(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify initial UI state
    expect(find.text('Bring Your Own Infrastructure'), findsOneWidget);

    // Find the text fields for Neo4j and Qdrant
    // We use the label text to find them
    final neo4jUriField = find.ancestor(
      of: find.text('Neo4j URI'),
      matching: find.byType(Column),
    ).first;

    // The actual TextField is a descendant of the Column
    await tester.enterText(
        find.descendant(of: neo4jUriField, matching: find.byType(TextField)),
        'bolt://test-neo4j:7687');

    final neo4jUserField = find.ancestor(
      of: find.text('Username'),
      matching: find.byType(Column),
    ).first;
    await tester.enterText(
        find.descendant(of: neo4jUserField, matching: find.byType(TextField)),
        'test_user');

    final qdrantUrlField = find.ancestor(
      of: find.text('Qdrant REST URL'),
      matching: find.byType(Column),
    ).first;
    await tester.enterText(
        find.descendant(of: qdrantUrlField, matching: find.byType(TextField)),
        'http://test-qdrant:6333');

    // Tap Save button
    await tester.tap(find.text('Save Configuration'));
    
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
