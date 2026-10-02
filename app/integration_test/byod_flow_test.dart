import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/infrastructure_tab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E2E infrastructure screen renders current settings state',
      (WidgetTester tester) async {
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
    expect(find.text('Qdrant Vector Database'), findsOneWidget);
    expect(find.text('Enterprise Feature'), findsOneWidget);
  });
}
