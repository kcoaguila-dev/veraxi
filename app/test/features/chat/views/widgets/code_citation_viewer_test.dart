import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/data/code_file_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_citation_viewer.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_citation_builder.dart';

class _FakeCodeFileRepository extends CodeFileRepository {
  _FakeCodeFileRepository(this._handler) : super(apiClient: ApiClient());

  final Future<CodeFileContent> Function(String path) _handler;

  @override
  Future<CodeFileContent> fetchFile(String path, {String? repoKey}) =>
      _handler(path);
}

CodeFileContent _fileContent({
  required int totalLines,
  int startLine = 1,
  String source = 'file',
  String path = 'backend/retrieval/merge_rank.py',
}) {
  final lines = List<String>.generate(totalLines, (i) {
    final n = startLine + i;
    return n == 214 ? 'def merge_rank(' : 'content of line $n';
  });
  return CodeFileContent(
    path: path,
    source: source,
    content: lines.join('\n'),
    lines: lines,
    startLine: startLine,
    endLine: startLine + totalLines - 1,
    lineCount: totalLines,
    language: 'python',
  );
}

Widget _wrapViewer(CodeCitationViewer viewer, CodeFileRepository repository) {
  return ProviderScope(
    overrides: [codeFileRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(theme: AppTheme.darkTheme, home: viewer),
  );
}

Widget _wrapMarkdown(
  String data,
  ChatMessage message,
  CodeFileRepository repository,
) {
  return ProviderScope(
    overrides: [codeFileRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
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
    ),
  );
}

void main() {
  group('CodeCitationTarget.tryParse', () {
    test('parses a line-range anchor', () {
      final target = CodeCitationTarget.tryParse(
        'file://backend/retrieval/merge_rank.py#L214-L303',
      );
      expect(target, isNotNull);
      expect(target!.path, 'backend/retrieval/merge_rank.py');
      expect(target.startLine, 214);
      expect(target.endLine, 303);
      expect(target.effectiveEndLine, 303);
    });

    test('parses a single-line anchor', () {
      final target =
          CodeCitationTarget.tryParse('file://backend/config.py#L42');
      expect(target, isNotNull);
      expect(target!.startLine, 42);
      expect(target.endLine, isNull);
      expect(target.effectiveEndLine, 42);
    });

    test('rejects a page anchor (document citation)', () {
      expect(
        CodeCitationTarget.tryParse('file://docs/book.pdf#page=158'),
        isNull,
      );
    });

    test('rejects a plain file URL and web URLs', () {
      expect(CodeCitationTarget.tryParse('file://backend/config.py'), isNull);
      expect(
        CodeCitationTarget.tryParse('https://example.com/x.py#L42'),
        isNull,
      );
    });
  });

  group('CodeCitationViewer', () {
    testWidgets(
        'renders the file, scrolls to the cited line, highlights the range',
        (tester) async {
      final repository = _FakeCodeFileRepository(
        (_) async => _fileContent(totalLines: 400),
      );
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _wrapViewer(
          CodeCitationViewer(
            target: const CodeCitationTarget(
              path: 'backend/retrieval/merge_rank.py',
              startLine: 214,
              endLine: 303,
            ),
            scrollController: controller,
          ),
          repository,
        ),
      );
      await tester.pumpAndSettle();

      // Full-file badge and cited-range caption.
      expect(find.text('Full file'), findsOneWidget);
      expect(find.text('Excerpt'), findsNothing);
      expect(find.textContaining('Cited lines 214–303'), findsOneWidget);

      // Scrolled so the first cited line is in view: ListView only
      // builds visible rows, and the offset matches the scroll math
      // (two context lines above the cited range).
      expect(
        controller.offset,
        (214 - 1 - 2) * CodeCitationViewer.lineHeight,
      );
      expect(find.text('def merge_rank('), findsOneWidget);

      // Cited rows carry the band color; context rows do not, so at
      // least the visible cited rows are banded.
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.color == CodeCitationViewer.citedBandColor,
        ),
        findsWidgets,
      );
    });

    testWidgets('excerpt content shows the Excerpt badge and real line numbers',
        (tester) async {
      final repository = _FakeCodeFileRepository(
        (_) async =>
            _fileContent(totalLines: 31, startLine: 180, source: 'excerpt'),
      );

      await tester.pumpWidget(
        _wrapViewer(
          const CodeCitationViewer(
            target: CodeCitationTarget(
              path: 'backend/retrieval/merge_rank.py',
              startLine: 182,
              endLine: 190,
            ),
          ),
          repository,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Excerpt'), findsOneWidget);
      expect(find.text('Full file'), findsNothing);
      // The gutter starts at the excerpt's first line, not at 1.
      expect(find.text('180'), findsOneWidget);
      expect(find.text('content of line 180'), findsOneWidget);
    });

    testWidgets('a failed load renders the unavailable state', (tester) async {
      final repository = _FakeCodeFileRepository(
        (_) async => throw Exception('Server error: 404'),
      );

      await tester.pumpWidget(
        _wrapViewer(
          const CodeCitationViewer(
            target: CodeCitationTarget(
              path: 'backend/retrieval/merge_rank.py',
              startLine: 214,
              endLine: 303,
            ),
          ),
          repository,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text("This file isn't available on the server."),
        findsOneWidget,
      );
      expect(find.text('Back'), findsOneWidget);
    });
  });

  group('Citation chip navigation', () {
    final launchedUrls = <String>[];

    setUp(() {
      launchedUrls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          final args = call.arguments;
          if (args is Map && args['url'] is String) {
            launchedUrls.add(args['url'] as String);
          }
          return true;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      );
    });

    testWidgets('tapping a line-anchored code citation opens the viewer',
        (tester) async {
      final repository = _FakeCodeFileRepository(
        (_) async => _fileContent(totalLines: 303),
      );
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
                  'text': 'The merge_rank function combines graph and '
                      'vector hits into one ranked list.',
                },
                'sources': ['Repo X-Ray'],
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg, repository));
      await tester.pumpAndSettle();
      expect(find.byType(CitationChip), findsOneWidget);

      await tester.tap(find.byType(CitationChip));
      await tester.pumpAndSettle();

      expect(find.byType(CodeCitationViewer), findsOneWidget);
      expect(find.text('def merge_rank('), findsOneWidget);
      // The citation never reached the external launcher.
      expect(launchedUrls, isEmpty);
    });

    testWidgets('tapping a #page= document citation still launches externally',
        (tester) async {
      final repository = _FakeCodeFileRepository(
        (_) async => _fileContent(totalLines: 10),
      );
      final msg = ChatMessage(
        role: 'assistant',
        content:
            'The rule is stated in the book [Some Book](file://docs/book.pdf#page=158).',
        toolEvents: [
          ToolEvent(
            id: 'td1',
            name: 'search_vectors',
            isComplete: true,
            result: [
              {
                'id': 'doc1',
                'payload': {
                  'title': 'Some Book',
                  'url': 'file://docs/book.pdf#page=158',
                  'text': 'An excerpt from the book.',
                },
                'sources': ['Knowledge Base'],
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(_wrapMarkdown(msg.content, msg, repository));
      await tester.pumpAndSettle();
      expect(find.byType(CitationChip), findsOneWidget);

      await tester.tap(find.byType(CitationChip));
      await tester.pumpAndSettle();

      expect(find.byType(CodeCitationViewer), findsNothing);
      // Historical behavior: the bare file path is launched, with
      // the page fragment stripped.
      expect(launchedUrls, ['file://docs/book.pdf']);
    });
  });
}
