import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_activity_disclosure.dart';

void main() {
  testWidgets('one disclosure expands thought process and activity',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatActivityDisclosure(
            reasoning: 'Inspecting the available context.',
            reasoningDurationSeconds: 1.2,
            activity: [
              ActivityStep(
                number: 1,
                name: 'Search context',
                description: 'Looking for relevant sources.',
                status: ActivityStepStatus.complete,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Search context'), findsOneWidget);
    expect(find.text('Thought process'), findsNothing);

    await tester.tap(find.text('Search context'));
    await tester.pumpAndSettle();

    expect(find.text('Thought process · 1.2s'), findsOneWidget);
    expect(find.text('Inspecting the available context.'), findsOneWidget);
    expect(find.text('Search context'), findsNWidgets(2));
  });
}
