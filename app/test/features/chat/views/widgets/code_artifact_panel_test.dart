import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:re_editor/re_editor.dart';
import 'package:drift/native.dart';
import 'package:veraxi_app/features/chat/data/artifact_publish_repository.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_store.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_incoming_provider.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_work_provider.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_quick_actions.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_list_item.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_artifact_card.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_artifact_panel.dart';

const _helloArtifact = CodeArtifact(
  title: 'Hello world',
  fileName: 'hello_world.py',
  language: 'python',
  code: 'def main():\n    print("Hello, World!")',
);

void _noop() {}

/// Hosts the panel the way the chat screen does, with the live
/// artifact provider pinned to the artifact under test (so the real
/// chat view model is never constructed).
Widget _hostPanel(
  CodeArtifact artifact, {
  VoidCallback? onClose,
  ValueChanged<String>? onQuickAction,
  List<Override> extraOverrides = const [],
  OpenCodeArtifact? openOverride,
}) {
  return ProviderScope(
    overrides: [
      openCodeArtifactLiveProvider.overrideWithValue(artifact),
      ...extraOverrides,
    ],
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(
        body: SizedBox(
          width: 520,
          child: CodeArtifactPanel(
            open: openOverride ?? OpenCodeArtifact(artifact: artifact),
            onClose: onClose ?? _noop,
            onQuickAction: onQuickAction,
          ),
        ),
      ),
    ),
  );
}

/// path_provider platform fake that roots every directory in [root].
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getDownloadsPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  testWidgets('card shows title and badge and fires onTap',
      (WidgetTester tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: CodeArtifactCard(
            artifact: _helloArtifact,
            onTap: () => taps++,
          ),
        ),
      ),
    );

    expect(find.text('Hello world'), findsOneWidget);
    expect(find.text('PY · 2 lines'), findsOneWidget);
    expect(find.byIcon(Icons.code), findsOneWidget);

    await tester.tap(find.byType(CodeArtifactCard));
    expect(taps, 1);
  });

  testWidgets('panel shows file header, editor, copy and close actions',
      (WidgetTester tester) async {
    var closed = false;
    await tester.pumpWidget(
      _hostPanel(_helloArtifact, onClose: () => closed = true),
    );
    await tester.pumpAndSettle();

    expect(find.text('hello_world.py'), findsOneWidget);
    expect(find.text('PY · Python'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    // The code lives in the workbench editor, starting at version 1,
    // read-only until Edit is tapped.
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('v1 / 1'), findsOneWidget);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.readOnly, isTrue);
    expect(editor.controller!.text, _helloArtifact.code);

    await tester.tap(find.byTooltip('Close'));
    expect(closed, isTrue);
  });

  testWidgets(
      'editing and finishing appends a version; versions navigate '
      'and diff against the previous one', (WidgetTester tester) async {
    await tester.pumpWidget(_hostPanel(_helloArtifact));
    await tester.pumpAndSettle();

    // No second version yet, so no Diff control.
    expect(find.text('Diff'), findsNothing);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    var editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.readOnly, isFalse);

    editor.controller!.codeLines = CodeLines.fromText(
      'def main():\n    print("Hello, Veraxi!")',
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('v2 / 2'), findsOneWidget);
    expect(find.text('Diff'), findsOneWidget);

    // Diff shows the changed line as removed + added.
    await tester.tap(find.text('Diff'));
    await tester.pumpAndSettle();
    expect(find.textContaining('+'), findsWidgets);
    expect(
      find.textContaining('print("Hello, Veraxi!")'),
      findsOneWidget,
    );
    await tester.tap(find.text('Diff'));
    await tester.pumpAndSettle();

    // Stepping back restores the original code in the editor.
    await tester.tap(find.byTooltip('Previous version'));
    await tester.pumpAndSettle();
    expect(find.text('v1 / 2'), findsOneWidget);
    editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.controller!.text, _helloArtifact.code);
  });

  testWidgets(
      'quick actions send a prompt built from the current code, and '
      'scope to the editor selection when there is one',
      (WidgetTester tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _hostPanel(_helloArtifact, onQuickAction: sent.add),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fix Bugs'), findsOneWidget);
    expect(find.text('Add Logs'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Comments'), findsOneWidget);

    await tester.tap(find.text('Fix Bugs'));
    expect(sent, hasLength(1));
    expect(sent.single, contains('hello_world.py'));
    expect(sent.single, contains('print("Hello, World!")'));
    expect(sent.single, isNot(contains('focus on lines')));

    // Select the second line in the editor: the next action scopes
    // to it and the hint appears.
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.selection = const CodeLineSelection(
      baseIndex: 1,
      baseOffset: 0,
      extentIndex: 1,
      extentOffset: 27,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Lines 2–2 selected'), findsOneWidget);

    await tester.tap(find.text('Review'));
    expect(sent, hasLength(2));
    expect(sent.last, contains('focus on lines 2–2'));
    expect(sent.last, contains('Full file for context:'));
  });

  testWidgets('quick actions are hidden when no handler is wired',
      (WidgetTester tester) async {
    await tester.pumpWidget(_hostPanel(_helloArtifact));
    await tester.pumpAndSettle();

    expect(find.text('Fix Bugs'), findsNothing);
    expect(find.text('Review'), findsNothing);
  });

  testWidgets('finishing an edit with no changes adds no version',
      (WidgetTester tester) async {
    await tester.pumpWidget(_hostPanel(_helloArtifact));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('v1 / 1'), findsOneWidget);
    expect(find.text('Diff'), findsNothing);
  });

  testWidgets('panel hides Run for languages the sandbox does not execute',
      (WidgetTester tester) async {
    const dartArtifact = CodeArtifact(
      title: 'Dart code',
      fileName: null,
      language: 'dart',
      code: "void main() => print('hi');",
    );
    await tester.pumpWidget(_hostPanel(dartArtifact));
    await tester.pumpAndSettle();

    expect(find.text('Run'), findsNothing);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets(
      'markdown panel opens on the rendered preview and toggles to code',
      (WidgetTester tester) async {
    const mdArtifact = CodeArtifact(
      title: 'Notes',
      fileName: 'notes.md',
      language: 'markdown',
      code: '# Release notes\n\nSome **bold** text.',
    );
    await tester.pumpWidget(_hostPanel(mdArtifact));
    await tester.pumpAndSettle();

    // Preview is the default for renderable artifacts: the heading is
    // rendered, the raw markdown and the gutter are not shown.
    expect(find.text('Release notes'), findsOneWidget);
    expect(find.text('Markdown preview'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    expect(find.byType(CodeEditor), findsNothing);

    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();

    // Code view: the workbench editor, no rendered heading.
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.text('Release notes'), findsNothing);

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Release notes'), findsOneWidget);
  });

  testWidgets('html message renders a previewable card that opens as html',
      (WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const content = '''
Here is the landing snippet:

```html
<button>Click me</button>
```
''';

    final theme = AppTheme.lightTheme;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: ChatMessageListItem(
              msg: ChatMessage(role: 'assistant', content: content),
              theme: theme,
              ext: theme.extension<AppThemeExtension>()!,
              showTelemetry: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodeArtifactCard), findsOneWidget);
    expect(find.text('HTML code'), findsOneWidget);

    await tester.tap(find.byType(CodeArtifactCard));
    await tester.pumpAndSettle();

    final opened = container.read(openCodeArtifactProvider);
    expect(opened, isNotNull);
    expect(opened!.artifact.previewKind, CodePreviewKind.html);
    expect(opened.artifact.isPreviewable, isTrue);
  });

  testWidgets(
      'artifact cards are collected at the end of the message, after '
      'the trailing prose, like Claude', (WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const content = '''
Here is the program:

```python
print("Hello, World!")
```

Run it with any Python interpreter.
''';

    final theme = AppTheme.lightTheme;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatMessageListItem(
                msg: ChatMessage(role: 'assistant', content: content),
                theme: theme,
                ext: theme.extension<AppThemeExtension>()!,
                showTelemetry: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The card exists, the code itself is not dumped inline, and the
    // card sits BELOW the prose that followed the block in the source.
    expect(find.byType(CodeArtifactCard), findsOneWidget);
    expect(find.textContaining('print("Hello'), findsNothing);
    final cardTop = tester.getTopLeft(find.byType(CodeArtifactCard)).dy;
    final proseTop =
        tester.getTopLeft(find.textContaining('Run it with any')).dy;
    expect(cardTop, greaterThan(proseTop));
  });

  testWidgets(
      'assistant message renders a card instead of the full code, '
      'and tapping it opens that artifact', (WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const content = '''
Here's `hello_world.py`:

```python
def main():
    print("Hello, World!")
```
''';

    final theme = AppTheme.lightTheme;
    // Seed chat state with the very message instance the item renders,
    // so the tap can record the artifact's coordinates for live
    // resolution.
    final msg = ChatMessage(role: 'assistant', content: content);
    container
        .read(chatViewModelProvider.notifier)
        .setStateForTesting(ChatState(messages: [msg]));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: ChatMessageListItem(
              msg: msg,
              theme: theme,
              ext: theme.extension<AppThemeExtension>()!,
              showTelemetry: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The compact card is in the flow; the panel is not open yet.
    expect(find.byType(CodeArtifactCard), findsOneWidget);
    expect(find.text('Hello world'), findsOneWidget);
    expect(container.read(openCodeArtifactProvider), isNull);

    await tester.tap(find.byType(CodeArtifactCard));
    await tester.pumpAndSettle();

    final opened = container.read(openCodeArtifactProvider);
    expect(opened, isNotNull);
    expect(opened!.artifact.fileName, 'hello_world.py');
    expect(opened.artifact.title, 'Hello world');
    expect(opened.artifact.code, contains('print("Hello, World!")'));
    expect(opened.messageIndex, 0);
    expect(opened.artifactIndex, 0);
  });

  testWidgets(
      'panel follows live content while streaming, until the user '
      'commits an edit of their own', (WidgetTester tester) async {
    final liveSource = StateProvider<CodeArtifact>((_) => _helloArtifact);
    final container = ProviderContainer(
      overrides: [
        openCodeArtifactLiveProvider
            .overrideWith((ref) => ref.watch(liveSource)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(
            body: SizedBox(
              width: 520,
              child: CodeArtifactPanel(
                open: OpenCodeArtifact(artifact: _helloArtifact),
                onClose: _noop,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    CodeLineEditingController editorController() =>
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

    expect(editorController().text, _helloArtifact.code);

    // The message streams in a longer version of the same block: the
    // panel follows it.
    const streamed = CodeArtifact(
      title: 'Hello world',
      fileName: 'hello_world.py',
      language: 'python',
      code: 'def main():\n    print("Hello, Stream!")',
    );
    container.read(liveSource.notifier).state = streamed;
    await tester.pumpAndSettle();
    expect(editorController().text, streamed.code);

    // The user commits their own edit — from now on their version
    // wins and the stream no longer overwrites it.
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    editorController().codeLines = CodeLines.fromText('user edit');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('v2 / 2'), findsOneWidget);

    const streamed2 = CodeArtifact(
      title: 'Hello world',
      fileName: 'hello_world.py',
      language: 'python',
      code: 'print("even later stream")',
    );
    container.read(liveSource.notifier).state = streamed2;
    await tester.pumpAndSettle();
    expect(editorController().text, 'user edit');
  });

  testWidgets('download saves the current version under its file name',
      (WidgetTester tester) async {
    // Real file IO cannot be awaited in the fake-async test body;
    // it goes through runAsync.
    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('artifact_download_test'),
    );
    addTearDown(() async {
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    // Point path_provider at the temp dir (the host platform's real
    // implementation would bypass a method-channel mock).
    PathProviderPlatform.instance = _FakePathProvider(tempDir!.path);

    await tester.pumpWidget(_hostPanel(_helloArtifact));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Download'), findsOneWidget);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();

    final saved = File('${tempDir.path}/hello_world.py');
    final exists = await tester.runAsync(() => saved.exists());
    expect(exists, isTrue);
    final contents = await tester.runAsync(() => saved.readAsString());
    expect(contents, _helloArtifact.code);
    // The "Saved to …" SnackBar is not asserted: its continuation is
    // chained on real IO under the fake-async clock and lands
    // unreliably in widget tests. The file on disk is the contract.
  });

  testWidgets(
      'share publishes through the repository and shows the link; '
      'unpublish from the dialog calls the backend', (tester) async {
    final repository = MockArtifactPublishRepository();
    when(() => repository.publish(
          title: any(named: 'title'),
          fileName: any(named: 'fileName'),
          language: any(named: 'language'),
          code: any(named: 'code'),
          kind: any(named: 'kind'),
          existingId: any(named: 'existingId'),
        )).thenAnswer(
      (_) async => const PublishedArtifact(
        id: 'abc',
        url: 'https://veraxi.me/a/abc',
      ),
    );
    when(() => repository.unpublish('abc')).thenAnswer((_) async {});

    await tester.pumpWidget(
      _hostPanel(
        _helloArtifact,
        extraOverrides: [
          artifactPublishRepositoryProvider.overrideWithValue(repository),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Share'), findsOneWidget);
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();

    // The share dialog shows the public link and its actions.
    expect(find.text('Share artifact'), findsOneWidget);
    expect(find.text('https://veraxi.me/a/abc'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    expect(find.text('Unpublish'), findsOneWidget);
    verify(() => repository.publish(
          title: 'Hello world',
          fileName: 'hello_world.py',
          language: 'python',
          code: _helloArtifact.code,
          kind: 'code',
          existingId: null,
        )).called(1);

    await tester.tap(find.text('Unpublish'));
    await tester.pumpAndSettle();

    verify(() => repository.unpublish('abc')).called(1);
    expect(find.text('Share artifact'), findsNothing);
  });

  group('incoming quick-action versions', () {
    const open = OpenCodeArtifact(
      artifact: _helloArtifact,
      threadId: 't1',
      messageIndex: 0,
    );

    /// Seeds a thread whose quick-action reply (fixed code) has
    /// completed, with the action registered as pending, and hosts
    /// the real panel against the real providers.
    Future<ProviderContainer> pumpPanelWithReply(
      WidgetTester tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(openCodeArtifactProvider.notifier).state = open;
      container.read(chatViewModelProvider.notifier).setStateForTesting(
            ChatState(
              threadId: 't1',
              messages: [
                ChatMessage(
                  role: 'assistant',
                  content: 'Here\'s `hello_world.py`:\n\n'
                      '```python\n'
                      'def main():\n'
                      '    print("Hello, World!")\n'
                      '```',
                ),
                ChatMessage(role: 'user', content: 'Fix the bugs...'),
                ChatMessage(
                  role: 'assistant',
                  content: 'Fixed:\n\n'
                      '```python\n'
                      'def main():\n'
                      '    print("Hello, fixed!")\n'
                      '```',
                ),
              ],
            ),
          );
      container.read(pendingQuickActionProvider.notifier).state =
          const PendingQuickAction(
        open: open,
        action: ArtifactQuickAction.fixBugs,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: SizedBox(
                width: 520,
                child: CodeArtifactPanel(
                  open: open,
                  onClose: _noop,
                  onQuickAction: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets(
        'the reply is offered as an incoming version; accepting '
        'appends it as a new version', (tester) async {
      final container = await pumpPanelWithReply(tester);

      expect(find.text('New version from Fix Bugs'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      // The pending action was consumed exactly once.
      expect(container.read(pendingQuickActionProvider), isNull);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      expect(find.text('New version from Fix Bugs'), findsNothing);
      expect(find.text('v2 / 2'), findsOneWidget);
    });

    testWidgets('rejecting keeps the current version only', (tester) async {
      await pumpPanelWithReply(tester);

      expect(find.text('New version from Fix Bugs'), findsOneWidget);
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();

      expect(find.text('New version from Fix Bugs'), findsNothing);
      expect(find.text('v2 / 2'), findsNothing);
    });
  });

  testWidgets(
      'panel restores persisted versions and the published link '
      'from a previous session', (tester) async {
    final db = LocalChatDatabase.withExecutor(NativeDatabase.memory());
    addTearDown(db.close);
    const editedCode = 'def main():\n    print("Hello, edited!")';
    await ArtifactWorkStore(database: db).save(
      't1:0:0',
      ArtifactWorkState(
        versions: [_helloArtifact.code, editedCode],
        versionIndex: 1,
        originalCode: _helloArtifact.code,
        publishedId: 'abc',
        publishedUrl: 'https://veraxi.me/a/abc',
        publishedCode: editedCode,
      ),
    );
    final repository = MockArtifactPublishRepository();

    await tester.pumpWidget(
      _hostPanel(
        _helloArtifact,
        openOverride: const OpenCodeArtifact(
          artifact: _helloArtifact,
          threadId: 't1',
          messageIndex: 0,
        ),
        extraOverrides: [
          artifactPublishRepositoryProvider.overrideWithValue(repository),
          // Local-only store: panel restore is the subject here;
          // sync behavior is covered by the store's own tests.
          artifactWorkStoreProvider
              .overrideWithValue(ArtifactWorkStore(database: db)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The restored session lands on the second version.
    expect(find.text('v2 / 2'), findsOneWidget);

    // The published link was restored too: Share opens the link
    // dialog directly, without publishing again (the restored code
    // is exactly what was published, so it is not stale).
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    expect(find.text('Share artifact'), findsOneWidget);
    expect(find.text('https://veraxi.me/a/abc'), findsOneWidget);
    verifyNever(() => repository.publish(
          title: any(named: 'title'),
          fileName: any(named: 'fileName'),
          language: any(named: 'language'),
          code: any(named: 'code'),
          kind: any(named: 'kind'),
          existingId: any(named: 'existingId'),
        ));
  });

  testWidgets(
      'when a save evicts the oldest work at the storage cap, the '
      'panel tells the user instead of staying silent', (tester) async {
    // Seed the local store at exactly its cap (none of the
    // entries is the artifact under test).
    final db = LocalChatDatabase.withExecutor(NativeDatabase.memory());
    addTearDown(db.close);
    final seedStore = ArtifactWorkStore(database: db);
    for (var i = 0; i < ArtifactWorkStore.maxEntries; i++) {
      await seedStore.save(
        'x:$i:0',
        ArtifactWorkState(
          versions: ['code $i'],
          versionIndex: 0,
          originalCode: 'code $i',
        ),
      );
    }
    final liveSource = StateProvider<CodeArtifact>((_) => _helloArtifact);
    final container = ProviderContainer(
      overrides: [
        openCodeArtifactLiveProvider
            .overrideWith((ref) => ref.watch(liveSource)),
        artifactWorkStoreProvider
            .overrideWithValue(ArtifactWorkStore(database: db)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(
            body: SizedBox(
              width: 520,
              child: CodeArtifactPanel(
                open: OpenCodeArtifact(
                  artifact: _helloArtifact,
                  threadId: 't1',
                  messageIndex: 0,
                ),
                onClose: _noop,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A stream update lands: the panel saves its work, the store
    // evicts the oldest entry to stay at the cap, and the user is
    // told about it.
    container.read(liveSource.notifier).state = const CodeArtifact(
      title: 'Hello world',
      fileName: 'hello_world.py',
      language: 'python',
      code: 'def main():\n    print("Hello, Stream!")',
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('oldest saved work was removed'),
      findsOneWidget,
    );
  });
}

/// mocktail fake for the publish repository (panel-level tests).
class MockArtifactPublishRepository extends Mock
    implements ArtifactPublishRepository {}
