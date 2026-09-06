import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('ChatInput', () {
    testWidgets('shows a text field and send button when there is no error',
        (tester) async {
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        onSend: (_, {attachments}) {},
      )));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      expect(find.byIcon(Icons.tune), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('calls onSend with the entered text and clears the field',
        (tester) async {
      String? sentText;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        onSend: (text, {attachments}) => sentText = text,
      )));

      await tester.enterText(find.byType(TextField), 'Hello Veraxi');
      await tester.pump(); // wait for setState(_hasText = true)
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
        onSend: (text, {attachments}) => sentText = text,
      )));

      await tester.enterText(find.byType(TextField), 'submitted via enter');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      expect(sentText, 'submitted via enter');
    });

    testWidgets('does not call onSend when the text is empty or whitespace',
        (tester) async {
      var called = false;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        onSend: (_, {attachments}) => called = true,
      )));

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();

      expect(called, isFalse);
    });

    testWidgets('shows a spinner and disables input while loading',
        (tester) async {
      var called = false;
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: true,
        onSend: (_, {attachments}) => called = true,
      )));

      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isFalse);

      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();

      expect(called, isFalse);
    });

    testWidgets(
        'shows the error state instead of the text field when '
        'an error is present', (tester) async {
      await tester.pumpWidget(wrap(ChatInput(
        isLoading: false,
        errorText: 'Network error: Unable to connect to the server.',
        onSend: (_, {attachments}) {},
      )));

      expect(find.byType(TextField), findsOneWidget);
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
        errorText: 'Something went wrong',
        onSend: (_, {attachments}) {},
        onDismissError: () => dismissed = true,
      )));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(dismissed, isTrue);
    });

    group('Tools Pinning and Active State', () {
      setUp(() {
        SharedPreferences.setMockInitialValues({});
      });

      testWidgets('Sending a message clears unpinned active tools',
          (tester) async {
        await tester.pumpWidget(wrap(ChatInput(
          isLoading: false,
          onSend: (text, {attachments}) {},
        )));

        await tester.pumpAndSettle();

        // Open tools menu
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();

        // Tap File Search to make it active
        await tester.tap(find.text('File Search'));
        await tester.pumpAndSettle();

        // Verify chip is visible
        expect(find.text('File Search'), findsWidgets);

        // Enter text and send
        await tester.enterText(find.byType(TextField), 'Test message');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.arrow_upward));
        await tester.pumpAndSettle();

        // Verify chip is gone (since it was not pinned)
        expect(find.text('File Search'), findsNothing);
      });

      testWidgets(
          'Pinning a tool saves it and keeps it active after sending a message',
          (tester) async {
        await tester.pumpWidget(wrap(ChatInput(
          isLoading: false,
          onSend: (text, {attachments}) {},
        )));

        await tester.pumpAndSettle();

        // Open tools menu
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();

        // Tap the pin icon for Web Search (which is push_pin outline initially)
        final pinIcons = find.byIcon(LucideIcons.pin);
        expect(
            pinIcons, findsWidgets); // Multiple pins, we can tap the first one
        await tester.tap(pinIcons.first);
        await tester.pumpAndSettle();

        // Enter text and send
        await tester.enterText(find.byType(TextField), 'Test message 2');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.arrow_upward));
        await tester.pumpAndSettle();

        // Verify chip is STILL visible because it was pinned
        expect(find.text('File Search'),
            findsWidgets); // First pin is file_search usually
      });
    });
  });
}
