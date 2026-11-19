import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/docs/views/docs_screen.dart';

void main() {
  Future<void> pumpDocs(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: DocsScreen())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders Quickstart guide by default and switches to API entry',
      (tester) async {
    await pumpDocs(tester);

    expect(find.text('Quickstart & Stack'), findsWidgets);
    expect(find.textContaining('make setup'), findsOneWidget);

    await tester.tap(find.text('/api/chat'));
    await tester.pumpAndSettle();

    expect(find.text('Fast & Deep Research Chat (SSE)'), findsOneWidget);
    expect(find.text('message'), findsOneWidget);
  });

  testWidgets('filter shows empty state and Clear filter restores items',
      (tester) async {
    await pumpDocs(tester);

    await tester.enterText(find.byType(TextField), 'zzznomatch');
    await tester.pumpAndSettle();

    expect(find.text('No matching guides or endpoints.'), findsOneWidget);

    await tester.tap(find.text('Clear filter'));
    await tester.pumpAndSettle();

    expect(find.text('/api/chat'), findsOneWidget);
  });
}
