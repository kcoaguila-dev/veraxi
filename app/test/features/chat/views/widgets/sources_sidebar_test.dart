import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_sidebar.dart';

void main() {
  testWidgets('SourcesSidebar renders list of sources with domains and titles', (WidgetTester tester) async {
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
  });
}
