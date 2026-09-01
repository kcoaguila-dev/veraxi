import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
        home: Scaffold(
          body: SourcesSidebar(sources: testSources),
        ),
      ),
    );

    // Should still render the title
    expect(find.text('Internal Database'), findsOneWidget);

    // Should NOT attempt to render an image if the domain is invalid
    final imageFinder = find.byType(Image);
    expect(imageFinder, findsNothing);
  });
}
