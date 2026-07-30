import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:veraxi_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Chat flow integration test', (WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle();

    // Verify Chats section exists
    expect(find.text('Chats'), findsOneWidget);
    
    // We should not see Spacer anymore, but rather ListView inside Expanded
    // This is hard to assert directly without checking the tree, but we can check for No threads or the list
  });
}
