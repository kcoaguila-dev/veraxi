import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/core/repositories/memory_repository.dart';
import 'package:veraxi_app/features/project/data/project_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';

void main() {
  testWidgets('ChatScreen shows past threads in desktop sidebar',
      (WidgetTester tester) async {
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
          chatViewModelProvider
              .overrideWith((ref) => MockChatViewModel(mockState)),
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

class MockChatRepository extends Mock implements ChatRepository {}
class MockTTSRepository extends Mock implements TTSRepository {}
class MockMemoryRepository extends Mock implements MemoryRepository {}
class MockProjectRepository extends Mock implements ProjectRepository {}

class MockChatViewModel extends ChatViewModel {
  MockChatViewModel(ChatState initialState) : super(MockChatRepository(), MockTTSRepository(), MockMemoryRepository()) {
    state = initialState;
  }

  @override
  Future<void> loadThreads() async {}

  @override
  void startNewChat() {}

  @override
  void toggleTemporaryChat() {}

  @override
  Future<void> toggleTelemetry() async {}




  @override
  void startNewChatInProject([String? projectId]) {}



  @override
  Future<void> selectThread(String threadId) async {}

  @override
  Future<void> editMessage(String messageId, String content) async {}

  @override
  void clearError() {}


  @override
  Future<void> saveToMemory(String content, {String? model}) async {}

  @override
  Future<void> regenerateResponse() async {}

  @override
  Future<void> sendMessage(String text,
      {List<dynamic>? attachments, String? model}) async {
    return super.noSuchMethod(
      Invocation.method(
          #sendMessage, [text], {#attachments: attachments, #model: model}),
    );
  }


  @override
  Future<void> submitFeedback(String messageId, int value) async {}

  @override
  Future<void> renameThread(String threadId, String newTitle) async {}
  @override
  Future<void> togglePinThread(String threadId) async {}
  @override
  Future<void> toggleArchiveThread(String threadId) async {}
  @override
  Future<void> deleteThread(String threadId) async {}
  @override
  Future<void> deleteAllChats() async {}
  @override
  Future<String?> duplicateThread(String threadId) async => null;
  @override
  Future<String?> shareThread(String threadId) async => null;

}
