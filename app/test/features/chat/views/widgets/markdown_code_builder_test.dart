import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_code_builder.dart';

/// Run is a capability, not a decoration: the legacy inline code block
/// shows its Run Code action only for languages the client sandbox can
/// actually execute (Python, JavaScript) — the same rule the artifact
/// panel follows. Any other language could only produce an error.
void main() {
  Future<void> pumpBlock(WidgetTester tester, String language) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: InteractiveCodeBlock(language: language, code: 'x = 1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows Run Code for python and javascript',
      (WidgetTester tester) async {
    await pumpBlock(tester, 'python');
    expect(find.text('Run Code'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);

    await pumpBlock(tester, 'javascript');
    expect(find.text('Run Code'), findsOneWidget);
  });

  testWidgets('hides Run Code for languages the sandbox cannot run',
      (WidgetTester tester) async {
    await pumpBlock(tester, 'dart');
    expect(find.text('Run Code'), findsNothing);
    // Copy stays available for every language.
    expect(find.text('Copy code'), findsOneWidget);

    await pumpBlock(tester, 'rust');
    expect(find.text('Run Code'), findsNothing);
  });
}
