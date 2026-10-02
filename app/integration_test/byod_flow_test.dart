import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/infrastructure_tab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E2E infrastructure screen renders current settings state',
      (WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: InfrastructureTab(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Infrastructure & Self-Hosting'), findsOneWidget);
    expect(find.text('Neo4j Graph Database'), findsOneWidget);
    expect(find.text('Neo4j Knowledge Graph'), findsOneWidget);
    expect(find.text('Qdrant Vector Database'), findsNWidgets(2));
    expect(find.text('Save Configuration'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'bolt://test-neo4j:7687');
    await tester.enterText(fields.at(1), 'test_user');
    await tester.enterText(fields.at(3), 'http://test-qdrant:6333');

    final saveButton = find.text('Save Configuration');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    final savedConfig = await ApiKeyStorage().getByodConfig();
    expect(savedConfig['neo4j_uri'], 'bolt://test-neo4j:7687');
    expect(savedConfig['neo4j_user'], 'test_user');
    expect(savedConfig['qdrant_url'], 'http://test-qdrant:6333');
    expect(find.text('Infrastructure settings saved locally.'), findsOneWidget);
  });
}
