import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/widgets/language_file_icon.dart';
import 'package:veraxi_app/features/chat/data/code_file_repository.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_citation_viewer.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_sidebar.dart';

void main() {
  testWidgets(
      'SourcesSidebar renders list of sources with domains, titles, and DuckDuckGo favicons',
      (WidgetTester tester) async {
    final List<Map<String, dynamic>> testSources = [
      {
        'url': 'https://example.com/test-article',
        'title': 'Test Article Title 1',
      },
      {
        'url': 'https://anotherexample.com/news',
        'title': 'Another Example News',
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SourcesSidebar(sources: testSources),
        ),
      ),
    );

    // Verify header
    expect(find.text('Sources'), findsOneWidget);

    // Verify titles are rendered in the sidebar
    expect(find.text('Test Article Title 1'), findsOneWidget);
    expect(find.text('Another Example News'), findsOneWidget);

    // Verify domains are rendered
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('anotherexample.com'), findsOneWidget);

    // Verify indexes
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // Verify that the CORS-friendly icon.horse API is being used for favicons
    final exampleImageFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is NetworkImage &&
          (widget.image as NetworkImage).url ==
              'https://icon.horse/icon/example.com',
    );
    expect(exampleImageFinder, findsOneWidget,
        reason: 'Proxy favicon for example.com must be rendered');

    final anotherExampleImageFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is NetworkImage &&
          (widget.image as NetworkImage).url ==
              'https://icon.horse/icon/anotherexample.com',
    );
    expect(anotherExampleImageFinder, findsOneWidget,
        reason: 'Proxy favicon for anotherexample.com must be rendered');
  });

  testWidgets(
      'SourcesSidebar renders provenance badges, fused score, and indented graph path',
      (WidgetTester tester) async {
    final List<Map<String, dynamic>> testSources = [
      {
        'url': '',
        'title': 'Acme Corp — Beta LLC acquisition filing',
        'provenance': {
          'legs': ['vector', 'graph'],
          'fused_score': 0.032,
          'graph_path': [
            {'node': 'Acme Corp', 'relation': 'ACQUIRED'},
            {'node': 'Beta LLC', 'relation': 'SUPPLIES'},
            {'node': 'Gamma Inc', 'relation': null},
          ],
        },
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SourcesSidebar(sources: testSources),
        ),
      ),
    );

    expect(find.byKey(ValueKey('provenance-section')), findsOneWidget);
    // Badges only for legs actually present.
    expect(find.text('Vector'), findsOneWidget);
    expect(find.text('Graph'), findsOneWidget);
    expect(find.text('Sparse'), findsNothing);
    // Fused score display.
    expect(find.text('Fused score'), findsOneWidget);
    expect(find.text('0.032'), findsOneWidget);
    // Graph path steps in order, with relation arrows.
    expect(find.text('Acme Corp'), findsOneWidget);
    expect(find.text('— ACQUIRED →'), findsOneWidget);
    expect(find.text('Beta LLC'), findsOneWidget);
    expect(find.text('— SUPPLIES →'), findsOneWidget);
    expect(find.text('Gamma Inc'), findsOneWidget);
    // Later steps are indented further than earlier ones.
    final firstNodeTop = tester.getTopLeft(find.text('Acme Corp'));
    final lastNodeTop = tester.getTopLeft(find.text('Gamma Inc'));
    expect(lastNodeTop.dx, greaterThan(firstNodeTop.dx));
  });

  testWidgets(
      'SourcesSidebar renders vector-only provenance without a graph path',
      (WidgetTester tester) async {
    final List<Map<String, dynamic>> testSources = [
      {
        'url': '',
        'title': 'Vector only chunk',
        'provenance': {
          'legs': ['vector'],
          'fused_score': 0.016,
          'graph_path': null,
        },
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SourcesSidebar(sources: testSources),
        ),
      ),
    );

    expect(find.text('Vector'), findsOneWidget);
    expect(find.text('Graph'), findsNothing);
    expect(find.text('0.016'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets(
      'SourcesSidebar without provenance renders the legacy card unchanged',
      (WidgetTester tester) async {
    final List<Map<String, dynamic>> testSources = [
      {
        'url': 'https://example.com/legacy',
        'title': 'Legacy Source',
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SourcesSidebar(sources: testSources),
        ),
      ),
    );

    expect(find.text('Legacy Source'), findsOneWidget);
    expect(find.byKey(ValueKey('provenance-section')), findsNothing);
    expect(find.text('PROVENANCE'), findsNothing);
    expect(find.text('Fused score'), findsNothing);
  });

  testWidgets('SourcesSidebar handles invalid or empty URLs gracefully',
      (WidgetTester tester) async {
    final List<Map<String, dynamic>> testSources = [
      {
        'url': '',
        'title': 'Internal Database',
      }
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SourcesSidebar(sources: testSources),
        ),
      ),
    );

    // Should still render the title
    expect(find.text('Internal Database'), findsWidgets);

    // Should NOT attempt to render an image if the domain is invalid
    final imageFinder = find.byType(Image);
    expect(imageFinder, findsNothing);
  });

  testWidgets(
      'SourcesSidebar renders High, Medium, and Low match tiers and hides raw fused score when showTelemetry is false',
      (WidgetTester tester) async {
    final List<Map<String, dynamic>> testSources = [
      {
        'url': '',
        'title': 'Multi-leg high hit',
        'provenance': {
          'legs': ['vector', 'graph'],
          'fused_score': 0.032,
          'graph_path': null,
        },
      },
      {
        'url': '',
        'title': 'Top single-leg medium hit',
        'provenance': {
          'legs': ['vector'],
          'fused_score': 0.016,
          'graph_path': null,
        },
      },
      {
        'url': '',
        'title': 'Tail low hit',
        'provenance': {
          'legs': ['vector'],
          'fused_score': 0.010,
          'graph_path': null,
        },
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SourcesSidebar(sources: testSources, showTelemetry: false),
        ),
      ),
    );

    expect(find.text('High match'), findsOneWidget);
    expect(find.text('Medium match'), findsOneWidget);
    expect(find.text('Low match'), findsOneWidget);
    expect(find.text('Fused score'), findsNothing);
    expect(find.text('0.032'), findsNothing);
    expect(find.text('0.016'), findsNothing);
    expect(find.text('0.010'), findsNothing);
  });

  testWidgets(
      'SourcesSidebar shows line range after code source title and opens CodeCitationViewer on tap',
      (WidgetTester tester) async {
    final testSources = [
      {
        'url': 'file://README.md#L1-L45',
        'title': 'README.md',
        'snippet': '# Veraxi\nHybrid GraphRAG architecture.',
      },
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          codeFileRepositoryProvider.overrideWithValue(
            _FakeCodeFileRepository(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: SourcesSidebar(sources: testSources),
          ),
        ),
      ),
    );

    expect(find.text('Repository File'), findsOneWidget);
    expect(find.text('README.md:1-45'), findsOneWidget);
    expect(find.byType(LanguageFileIcon), findsOneWidget);

    await tester.tap(find.text('README.md:1-45'));
    await tester.pumpAndSettle();

    expect(find.byType(CodeCitationViewer), findsOneWidget);
  });

  testWidgets(
      'SourcesSidebar opens plain repo file:// source in CodeCitationViewer and shows directory label',
      (WidgetTester tester) async {
    final testSources = [
      {
        'url': 'file://backend/retrieval/merge_rank.py',
        'title': 'merge_rank.py',
        'snippet': 'def merge_rank(): ...',
      },
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          codeFileRepositoryProvider.overrideWithValue(
            _FakeCodeFileRepository(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: SourcesSidebar(sources: testSources),
          ),
        ),
      ),
    );

    expect(find.text('backend/retrieval'), findsOneWidget);
    expect(find.text('merge_rank.py'), findsOneWidget);

    await tester.tap(find.text('merge_rank.py'));
    await tester.pumpAndSettle();

    expect(find.byType(CodeCitationViewer), findsOneWidget);
  });

  testWidgets(
      'SourcesSidebar opens snippet preview dialog when internal source has no URL',
      (WidgetTester tester) async {
    final testSources = [
      {
        'url': '',
        'title': 'Architecture Notes',
        'snippet': 'Full internal chunk content for preview.',
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SourcesSidebar(sources: testSources),
        ),
      ),
    );

    await tester.tap(find.text('Architecture Notes'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Full internal chunk content for preview.'),
        findsWidgets);
  });
}

class _FakeCodeFileRepository extends CodeFileRepository {
  _FakeCodeFileRepository() : super(apiClient: ApiClient());

  @override
  Future<CodeFileContent> fetchFile(String path, {String? repoKey}) async {
    return const CodeFileContent(
      path: 'README.md',
      source: 'file',
      content: '# Veraxi\nHybrid GraphRAG',
      lines: ['# Veraxi', 'Hybrid GraphRAG'],
      startLine: 1,
      endLine: 2,
      lineCount: 2,
    );
  }
}
