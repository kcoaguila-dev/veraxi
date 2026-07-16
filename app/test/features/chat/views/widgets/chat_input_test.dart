import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('ChatInput', () {
    testWidgets('shows a text field and send button when there is no error',
        (tester) async {
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        onSend: (_) {},
      )));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('calls onSend with the entered text and clears the field',
        (tester) async {
      String? sentText;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        onSend: (text) => sentText = text,
      )));

      await tester.enterText(find.byType(TextField), 'Hello Veraxi');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();

      expect(sentText, 'Hello Veraxi');
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, isEmpty);
    });

    testWidgets('submitting via the keyboard action also sends the message',
        (tester) async {
      String? sentText;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        onSend: (text) => sentText = text,
      )));

      await tester.enterText(find.byType(TextField), 'submitted via enter');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(sentText, 'submitted via enter');
    });

    testWidgets('does not call onSend when the text is empty or whitespace',
        (tester) async {
      var called = false;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        onSend: (_) => called = true,
      )));

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();

      expect(called, isFalse);
    });

    testWidgets('shows a spinner and disables input while loading',
        (tester) async {
      var called = false;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: true,
        onSend: (_) => called = true,
      )));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isFalse);

      await tester.tap(find.byType(IconButton));
      await tester.pump();

      expect(called, isFalse);
    });

    testWidgets('shows the error state instead of the text field when '
        'an error is present', (tester) async {
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        error: 'Network error: Unable to connect to the server.',
        onSend: (_) {},
      )));

      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(
        find.text('Network error: Unable to connect to the server.'),
        findsOneWidget,
      );
    });

    testWidgets('calls onDismissError when the close icon is tapped',
        (tester) async {
      var dismissed = false;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        error: 'Something went wrong',
        onSend: (_) {},
        onDismissError: () => dismissed = true,
      )));

      await tester.tap(find.byTooltip('Dismiss error'));
      await tester.pump();

      expect(dismissed, isTrue);
    });
  });
}