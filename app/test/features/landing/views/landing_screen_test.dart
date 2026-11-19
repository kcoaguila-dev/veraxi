import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/landing_screen.dart';

void main() {
  Future<void> pumpLanding(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LandingScreen())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('has exactly one Start Building button', (tester) async {
    await pumpLanding(tester);

    // The integration tests tap this text to reach the login screen, so it
    // must stay unique on the page.
    expect(find.text('Start Building'), findsOneWidget);
  });

  testWidgets('shows the first sample answer with its sources', (tester) async {
    await pumpLanding(tester);

    expect(find.textContaining('Give written notice by'), findsOneWidget);
    // File names also appear in the path chain, so match the location lines.
    expect(find.text('Page 4, Ending the lease'), findsOneWidget);
    expect(find.text('Nov 3, Re: Moving out'), findsOneWidget);
  });

  testWidgets('picking another question swaps the answer and sources',
      (tester) async {
    await pumpLanding(tester);

    await tester.tap(
      find.text(
          'Does a final exam land on the same day as a project deadline?'),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Yes. On'), findsOneWidget);
    expect(find.text('Page 1, Assessment'), findsOneWidget);
    expect(find.text('Page 4, Ending the lease'), findsNothing);
  });

  testWidgets('selecting a phrase marks only the passages it relies on',
      (tester) async {
    await pumpLanding(tester);

    // The first phrase combines the lease and the email.
    expect(find.text('Used for the selected phrase'), findsNWidgets(2));

    await tester.tap(find.textContaining('60 days of written notice'));
    await tester.pumpAndSettle();

    // The second phrase comes from the lease alone.
    expect(find.text('Used for the selected phrase'), findsOneWidget);
  });
}
