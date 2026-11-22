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

  testWidgets(
      'expanding activity humanizes internal steps and shows hybrid channels, query args, and counts',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatActivityDisclosure(
            reasoningDurationSeconds: 1.8,
            activity: [
              ActivityStep(
                number: 1,
                name: 'Planning & Discovery',
                description: 'Analyzing intent and selecting domain tools...',
                status: ActivityStepStatus.complete,
                toolEvents: [
                  ToolEvent(
                    id: 't1',
                    name: 'search_vectors',
                    args: {'query_text': 'whos the ceo of nvidia'},
                    isComplete: true,
                    result: [
                      {
                        'id': 'c1',
                        'provenance': {
                          'legs': ['vector', 'graph'],
                          'fused_score': 0.032,
                        },
                      },
                      {
                        'id': 'c2',
                        'provenance': {
                          'legs': ['vector'],
                          'fused_score': 0.016,
                        },
                      },
                    ],
                  ),
                  ToolEvent(
                    id: 't2',
                    name: 'mcp_query_graph',
                    args: {'entity_name': 'NVIDIA'},
                    isComplete: true,
                    result: [
                      {'id': 'g1'},
                    ],
                  ),
                ],
              ),
              const ActivityStep(
                number: 2,
                name: 'Answer Synthesis',
                description:
                    'Synthesizing answer grounded in retrieved knowledge...',
                status: ActivityStepStatus.complete,
              ),
            ],
          ),
        ),
      ),
    );

    final summaryFinder = find.text(
      'Thought for 1.8s · Checked your corpus · Traversed knowledge graph',
    );
    expect(summaryFinder, findsOneWidget);

    await tester.tap(summaryFinder);
    await tester.pumpAndSettle();

    expect(find.text('Retrieved evidence'), findsOneWidget);
    expect(find.text('Checked Hybrid Vector, Knowledge Graph'), findsOneWidget);
    expect(find.text('Drafted grounded answer'), findsOneWidget);
    expect(find.text('Grounded in retrieved sources'), findsOneWidget);
    expect(find.text('Planning & Discovery'), findsNothing);
    expect(find.text('Answer Synthesis'), findsNothing);

    expect(find.text('Hybrid Vector Search'), findsOneWidget);
    expect(find.text('Knowledge Graph Traversal'), findsOneWidget);
    expect(
      find.text('"whos the ceo of nvidia" · 2 results · Vector + Graph'),
      findsOneWidget,
    );
    expect(find.text('"NVIDIA" · 1 result'), findsOneWidget);
    expect(find.text('Vector'), findsOneWidget);
    expect(find.text('Graph'), findsOneWidget);
  });
}
