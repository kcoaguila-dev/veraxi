import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';

void main() {
  testWidgets('ChatScreen shows past threads in desktop sidebar', (WidgetTester tester) async {
    // We will set a wide screen size to trigger desktop layout
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;

    final mockState = ChatState(
      pastThreads: [
        {'thread_id': 'thread-1', 'title': 'Test Chat 1'},
        {'thread_id': 'thread-2', 'title': 'Test Chat 2'},
      ],
      messages: [],
    );

    // Provide the mock state
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => MockChatViewModel(mockState)),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify that the titles are rendered
    expect(find.text('Test Chat 1'), findsOneWidget);
    expect(find.text('Test Chat 2'), findsOneWidget);

    // Reset size
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

class MockChatViewModel extends StateNotifier<ChatState> implements ChatViewModel {
  MockChatViewModel(ChatState state) : super(state);

  @override
  Future<void> loadThreads() async {}

  @override
  void startNewChat() {}

  @override
  void toggleTemporaryChat() {}

  @override
  Future<void> selectThread(String threadId) async {}
  
  @override
  Future<void> editMessage(String messageId, String content) async {}

  @override
  void clearError() {}

  @override
  Future<void> playAudio(String text, {required String messageId}) async {}

  @override
  Future<void> regenerateResponse() async {}

  @override
  Future<void> sendMessage(String text, {String? model}) async {}

  @override
  void stopAudio() {}

  @override
  Future<void> submitFeedback(String messageId, int value) async {}
}
