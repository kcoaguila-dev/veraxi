import 'package:material_ui/material_ui.dart';
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

  testWidgets(
      'internal stages with tool events show plain-language summary with thought duration',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatActivityDisclosure(
            reasoning: 'Let me check web and corpus sources.',
            reasoningDurationSeconds: 2.5,
            activity: [
              ActivityStep(
                number: 1,
                name: 'Planning & Discovery',
                status: ActivityStepStatus.complete,
                toolEvents: [
                  ToolEvent(id: 't1', name: 'web_search', isComplete: true),
                  ToolEvent(id: 't2', name: 'search_vectors', isComplete: true),
                ],
              ),
              const ActivityStep(
                number: 2,
                name: 'Answer Synthesis',
                status: ActivityStepStatus.complete,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.text('Thought for 2.5s · Searched the web · Checked your corpus'),
      findsOneWidget,
    );
    expect(find.text('Planning & Discovery, Answer Synthesis'), findsNothing);
  });

  testWidgets(
      'internal stages without tools show plain-language fallback labels',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatActivityDisclosure(
            activity: [
              ActivityStep(
                number: 1,
                name: 'Planning & Discovery',
                status: ActivityStepStatus.complete,
              ),
              ActivityStep(
                number: 2,
                name: 'Answer Synthesis',
                status: ActivityStepStatus.complete,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.text('Analyzed question · Drafted grounded answer'),
      findsOneWidget,
    );
  });
}
