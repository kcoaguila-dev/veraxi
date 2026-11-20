import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_citation_builder.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_button.dart';

Widget _wrapMarkdown(String data, ChatMessage message) {
  return MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 700,
          child: MarkdownBody(
            data: data,
            extensionSet: md.ExtensionSet(
              md.ExtensionSet.gitHubFlavored.blockSyntaxes,
              [
                CitationSyntax(),
                ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
              ],
            ),
            builders: {
              'a': CitationElementBuilder(message: message),
              'cite': CitationElementBuilder(message: message),
            },
          ),
        ),
      ),
    ),
  );
}

Future<TestGesture> _hoverOver(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
  return gesture;
}

void main() {
  group('CitationSyntax & CitationChip grouping', () {
    testWidgets('single source pill renders label without +N suffix',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'Colette Kress is interim CEO [Colette Kress - Wikipedia].',
        toolEvents: [
          ToolEvent(
            id: 't1',
            name: 'web_search',
            isComplete: true,
            result: [
              {
                'title': 'Colette Kress - Wikipedia',
                'url': 'https://en.wikipedia.org/wiki/Colette_Kress',
                'content': 'Colette Marie Kress is an American executive.',
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsOneWidget);
      expect(find.text('Colette Kress - Wikipedia'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets(
        'two consecutive sources combine into one pill with first source and +1',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content:
            'Colette Kress is interim CEO [Colette Kress - Wikipedia] [Finance Yahoo].',
        toolEvents: [
          ToolEvent(
            id: 't2',
            name: 'web_search',
            isComplete: true,
            result: [
              {
                'title': 'Colette Kress - Wikipedia',
                'url': 'https://en.wikipedia.org/wiki/Colette_Kress',
                'content': 'Wikipedia bio snippet.',
              },
              {
                'title':
                    'NVIDIA Names Colette Kress Interim CEO - Yahoo Finance',
                'url': 'https://finance.yahoo.com/news/nvidia-kress-123.html',
                'content': 'Yahoo Finance article snippet.',
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsOneWidget);
      expect(find.text('Colette Kress - Wikipedia'), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('Finance Yahoo'), findsNothing);
    });

    testWidgets(
        'three consecutive sources combine into one pill with first source and +2',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'Market update [Source A] [Source B] [Source C].',
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsOneWidget);
      expect(find.text('Source A'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets(
        'markdown links with explicit URLs preserve URLs and group into one pill',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content:
            'Update [Colette Kress - Wikipedia](https://en.wikipedia.org/wiki/Colette_Kress) [Finance Yahoo](https://finance.yahoo.com/quote/NVDA).',
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsOneWidget);
      expect(find.text('Colette Kress - Wikipedia'), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);

      final gesture = await _hoverOver(tester, find.byType(CitationChip));
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('2 sources'), findsOneWidget);
      expect(find.text('wikipedia'), findsOneWidget);

      await gesture.moveTo(tester.getCenter(find.byIcon(Icons.chevron_right)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('yahoo'), findsOneWidget);
      expect(find.text('Knowledge Base'), findsNothing);
    });

    testWidgets(
        'citations across separate sentences stay separate pills instead of merging',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'First claim [Source A]. Second claim [Source B].',
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsNWidgets(2));
      expect(find.text('Source A'), findsOneWidget);
      expect(find.text('Source B'), findsOneWidget);
      expect(find.text('+1'), findsNothing);
    });

    testWidgets('numeric multi-citation [1, 2, 3] renders first source and +2',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'Indices fell [1, 2, 3].',
        toolEvents: [
          ToolEvent(
            id: 't3',
            name: 'web_search',
            isComplete: true,
            result: [
              {
                'title': 'Schwab Market Update',
                'url': 'https://www.schwab.com/learn/story/market-update',
                'content': 'Stocks dipped slightly.',
              },
              {
                'title': 'Reuters Markets',
                'url': 'https://www.reuters.com/markets/us',
                'content': 'Wall Street fell.',
              },
              {
                'title': 'Bloomberg Stocks',
                'url': 'https://www.bloomberg.com/markets',
                'content': 'Global indices snapshot.',
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsOneWidget);
      expect(find.text('Schwab'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
    });
  });

  group('Hover card & Finance Yahoo matching regression', () {
    testWidgets(
        'hovering multi-source pill shows 1/2, 2 sources, and paginates to Finance Yahoo without Knowledge Base',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content:
            'Colette Marie Kress is interim CEO [Colette Kress - Wikipedia] [Finance Yahoo].',
        toolEvents: [
          ToolEvent(
            id: 't4',
            name: 'web_search',
            isComplete: true,
            result: [
              {
                'title': 'Colette Kress - Wikipedia',
                'url': 'https://en.wikipedia.org/wiki/Colette_Kress',
                'content': 'Colette Marie Kress is an American executive.',
              },
              {
                'id': 'hit-2',
                'payload': {
                  'title':
                      'NVIDIA Announces Executive Transition - Yahoo Finance',
                  'url':
                      'https://finance.yahoo.com/news/nvidia-transition-999.html',
                  'text': 'Colette Kress serves as interim CEO of NVIDIA.',
                },
                'sources': ['vector'],
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      final gesture = await _hoverOver(tester, find.byType(CitationChip));

      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('2 sources'), findsOneWidget);
      expect(find.text('wikipedia'), findsOneWidget);
      expect(find.text('Colette Marie Kress is an American executive.'),
          findsOneWidget);
      expect(find.text('Knowledge Base'), findsNothing);

      await gesture.moveTo(tester.getCenter(find.byIcon(Icons.chevron_right)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('yahoo'), findsOneWidget);
      expect(
        find.text('NVIDIA Announces Executive Transition - Yahoo Finance'),
        findsOneWidget,
      );
      expect(
        find.text('Colette Kress serves as interim CEO of NVIDIA.'),
        findsOneWidget,
      );
      expect(find.text('Knowledge Base'), findsNothing);

      await gesture.moveTo(tester.getCenter(find.byIcon(Icons.chevron_left)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();

      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('wikipedia'), findsOneWidget);
    });

    testWidgets(
        'standalone [Finance Yahoo] matches finance.yahoo.com and never shows Knowledge Base',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'NVIDIA shares moved [Finance Yahoo].',
        toolEvents: [
          ToolEvent(
            id: 't5',
            name: 'web_search',
            isComplete: true,
            result: [
              {
                'title': 'NVIDIA Stock Update',
                'url': 'https://finance.yahoo.com/quote/NVDA',
                'content': 'Latest NVDA market summary.',
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      await _hoverOver(tester, find.byType(CitationChip));

      expect(find.text('yahoo'), findsOneWidget);
      expect(find.text('NVIDIA Stock Update'), findsOneWidget);
      expect(find.text('Latest NVDA market summary.'), findsOneWidget);
      expect(find.text('Knowledge Base'), findsNothing);
    });

    testWidgets(
        'unmatched [Finance Yahoo] without tool events shows Finance Yahoo, never Knowledge Base',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'NVIDIA shares moved [Finance Yahoo].',
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      await _hoverOver(tester, find.byType(CitationChip));

      expect(find.text('Finance Yahoo'), findsNWidgets(2));
      expect(find.text('Knowledge Base'), findsNothing);
    });

    testWidgets(
        'internal vector hit without URL or title still displays Knowledge Base',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'Internal policy applies [1].',
        toolEvents: [
          ToolEvent(
            id: 't6',
            name: 'search_vectors',
            isComplete: true,
            result: [
              {
                'id': 'kb-1',
                'payload': {
                  'text': 'Internal knowledge chunk text.',
                },
                'sources': ['vector'],
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      await _hoverOver(tester, find.byType(CitationChip));

      expect(find.text('Knowledge Base'), findsOneWidget);
    });
  });

  group('fileCitationLaunchUrl', () {
    test('preserves a line-range anchor from a code citation', () {
      expect(
        fileCitationLaunchUrl(
            'file://backend/retrieval/merge_rank.py#L214-L303'),
        'file://backend/retrieval/merge_rank.py#L214-L303',
      );
    });

    test('preserves a single-line anchor from a code citation', () {
      expect(
        fileCitationLaunchUrl('file://backend/retrieval/code_queries.py#L42'),
        'file://backend/retrieval/code_queries.py#L42',
      );
    });

    test('strips a page anchor, keeping the historical bare-file launch', () {
      expect(
        fileCitationLaunchUrl('file://docs/book.pdf#page=158'),
        'file://docs/book.pdf',
      );
    });

    test('strips any other non-line fragment', () {
      expect(
        fileCitationLaunchUrl('file://docs/notes.md#section-2'),
        'file://docs/notes.md',
      );
    });

    test('returns an anchorless file URL unchanged', () {
      expect(
        fileCitationLaunchUrl('file://backend/config.py'),
        'file://backend/config.py',
      );
    });
  });

  group('Code tool source events', () {
    testWidgets(
        'code_symbol event feeds hover-card enrichment for a code citation',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content:
            'The merge step lives in the retrieval layer [merge_rank](file://backend/retrieval/merge_rank.py#L214-L303).',
        toolEvents: [
          ToolEvent(
            id: 'tc1',
            name: 'mcp_code_symbol',
            isComplete: true,
            result: [
              {
                'id': 'code_graph',
                'payload': {
                  'title': 'merge_rank',
                  'url': 'file://backend/retrieval/merge_rank.py#L214-L303',
                  'text':
                      'The merge_rank function combines graph and vector hits into one ranked list.',
                },
                'sources': ['Repo X-Ray'],
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsOneWidget);

      await _hoverOver(tester, find.byType(CitationChip));

      expect(find.text('merge_rank'), findsWidgets);
      expect(
        find.text(
            'The merge_rank function combines graph and vector hits into one ranked list.'),
        findsOneWidget,
      );
      expect(find.text('Knowledge Base'), findsNothing);
    });

    test('SourcesButton.extractSources includes code tool events', () {
      final msg = ChatMessage(
        role: 'assistant',
        content:
            'The overview entry point is [code_queries](file://backend/retrieval/code_queries.py).',
        toolEvents: [
          ToolEvent(
            id: 'tc2',
            name: 'code_impact',
            isComplete: true,
            result: [
              {
                'id': 'code_graph',
                'payload': {
                  'title': 'code_queries',
                  'url': 'file://backend/retrieval/code_queries.py',
                  'text': 'Repo X-Ray query layer for the code graph.',
                },
                'sources': ['Repo X-Ray'],
              },
            ],
          ),
        ],
      );

      final sources = SourcesButton.extractSources(msg);

      expect(sources, hasLength(1));
      expect(sources.single['url'],
          'file://backend/retrieval/code_queries.py');
      expect(sources.single['title'], 'code_queries');
    });
  });

  group('Claim-matched verbatim excerpt extraction', () {
    testWidgets(
        'prefers the exact supporting sentence from full text over generic meta snippet',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content:
            'Colette Kress became interim CEO of NVIDIA in November 2026 [Colette Kress - Wikipedia].',
        toolEvents: [
          ToolEvent(
            id: 't-excerpt-1',
            name: 'web_search',
            isComplete: true,
            result: [
              {
                'id': 'wiki-1',
                'payload': {
                  'title': 'Colette Kress - Wikipedia',
                  'url': 'https://en.wikipedia.org/wiki/Colette_Kress',
                  'snippet': 'Generic meta description for Wikipedia article.',
                  'text': 'Colette Marie Kress grew up in the Midwest and earned an MBA. '
                      'She joined NVIDIA as CFO in 2013 after working at Cisco. '
                      'In November 2026, Colette Kress was appointed interim CEO of NVIDIA following Jensen Huang stepping down.',
                },
                'sources': ['vector'],
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      await _hoverOver(tester, find.byType(CitationChip));

      expect(
        find.text(
          'In November 2026, Colette Kress was appointed interim CEO of NVIDIA following Jensen Huang stepping down.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Generic meta description for Wikipedia article.'),
        findsNothing,
      );
    });

    testWidgets(
        'same source cited in two sentences shows each claim-specific excerpt on hover',
        (tester) async {
      final msg = ChatMessage(
        role: 'assistant',
        content: 'Acme completed the Beta acquisition in 2023 [Acme Filing]. '
            'The combined unit generated 480 million in annual recurring revenue [Acme Filing].',
        toolEvents: [
          ToolEvent(
            id: 't-excerpt-2',
            name: 'web_search',
            isComplete: true,
            result: [
              {
                'id': 'acme-1',
                'payload': {
                  'title': 'Acme Filing',
                  'url': 'https://sec.gov/acme-filing',
                  'snippet': 'Acme Corporation regulatory filing summary.',
                  'text': 'Acme Corporation was incorporated in Delaware in 2011. '
                      'On May 4, 2023, Acme completed the acquisition of Beta LLC for cash. '
                      'The combined business reached 480 million in annual recurring revenue by year end.',
                },
                'sources': ['vector'],
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg));
      await tester.pumpAndSettle();

      expect(find.byType(CitationChip), findsNWidgets(2));

      final gesture = await _hoverOver(tester, find.byType(CitationChip).at(0));
      expect(
        find.text(
          'On May 4, 2023, Acme completed the acquisition of Beta LLC for cash.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'The combined business reached 480 million in annual recurring revenue by year end.',
        ),
        findsNothing,
      );

      await gesture.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      await gesture.moveTo(tester.getCenter(find.byType(CitationChip).at(1)));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'The combined business reached 480 million in annual recurring revenue by year end.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'On May 4, 2023, Acme completed the acquisition of Beta LLC for cash.',
        ),
        findsNothing,
      );
    });
  });
}
