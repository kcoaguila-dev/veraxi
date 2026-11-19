import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_citation_builder.dart';

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
}
