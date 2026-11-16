import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
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

  testWidgets('panel shows file header, gutter, copy and close actions',
      (WidgetTester tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SizedBox(
            width: 520,
            child: CodeArtifactPanel(
              artifact: _helloArtifact,
              onClose: () => closed = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('hello_world.py'), findsOneWidget);
    expect(find.text('PY · Python'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    // Line-number gutter for the two lines of code.
    expect(find.text('1\n2'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    expect(closed, isTrue);
  });

  testWidgets('panel hides Run for languages the sandbox does not execute',
      (WidgetTester tester) async {
    const dartArtifact = CodeArtifact(
      title: 'Dart code',
      fileName: null,
      language: 'dart',
      code: "void main() => print('hi');",
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SizedBox(
            width: 520,
            child: CodeArtifactPanel(
              artifact: dartArtifact,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
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
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: SizedBox(
            width: 520,
            child: CodeArtifactPanel(
              artifact: mdArtifact,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Preview is the default for renderable artifacts: the heading is
    // rendered, the raw markdown and the gutter are not shown.
    expect(find.text('Release notes'), findsOneWidget);
    expect(find.text('Markdown preview'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    expect(find.text('1\n2\n3'), findsNothing);

    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();

    // Code view: line gutter for the three lines, no rendered heading.
    expect(find.text('1\n2\n3'), findsOneWidget);
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
    expect(opened!.previewKind, CodePreviewKind.html);
    expect(opened.isPreviewable, isTrue);
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

    // The compact card is in the flow; the panel is not open yet.
    expect(find.byType(CodeArtifactCard), findsOneWidget);
    expect(find.text('Hello world'), findsOneWidget);
    expect(container.read(openCodeArtifactProvider), isNull);

    await tester.tap(find.byType(CodeArtifactCard));
    await tester.pumpAndSettle();

    final opened = container.read(openCodeArtifactProvider);
    expect(opened, isNotNull);
    expect(opened!.fileName, 'hello_world.py');
    expect(opened.title, 'Hello world');
    expect(opened.code, contains('print("Hello, World!")'));
  });
}
