import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_button.dart';

void main() {
  testWidgets('SourcesButton renders sources count extracted from tool events', (WidgetTester tester) async {
    // Create a mock ToolEvent with web_search result containing an artifact
    final toolEvent = ToolEvent(
      id: 'test-tool',
      name: 'web_search',
      isComplete: true,
      result: [
        {
          'url': 'https://example.com/news1',
          'title': 'Test News 1',
        },
        {
          'link': 'https://anotherexample.com/article',
          'title': 'Test Article 2',
        }
      ],
    );

    final message = ChatMessage(
      role: 'assistant',
      content: 'Here is the news [1](https://example.com/news1)',
      toolEvents: [toolEvent],
    );

    bool callbackFired = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourcesButton(
            message: message,
            onSourceClicked: () {
              callbackFired = true;
            },
          ),
        ),
      ),
    );

    // Verify the "X sources" text is rendered
    expect(find.text('2 sources'), findsOneWidget);

    // Verify that the titles are NOT rendered
    expect(find.text('Test News 1'), findsNothing);
    expect(find.text('Test Article 2'), findsNothing);
    
    // Tap the button and verify callback
    await tester.tap(find.text('2 sources'));
    expect(callbackFired, isTrue);
  });
}

