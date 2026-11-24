import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/core/repositories/memory_repository.dart';
import 'package:veraxi_app/features/project/data/project_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  List<ChatMessage> buildLongHistory() => List<ChatMessage>.generate(
        20,
        (i) => ChatMessage(
          role: 'user',
          content: 'Message $i\nLine 2\nLine 3\nLine 4',
        ),
      );

  Future<MockChatViewModel> pumpChatScreen(
    WidgetTester tester,
    ChatState initialState,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final viewModel = MockChatViewModel(initialState);
    final codeViewModel = MockChatViewModel(ChatState(messages: []));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => viewModel),
          codeChatViewModelProvider.overrideWith((ref) => codeViewModel),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    return viewModel;
  }

  testWidgets('ChatScreen shows past threads in desktop sidebar',
      (WidgetTester tester) async {
    final mockState = ChatState(
      pastThreads: [
        {'thread_id': 'thread-1', 'title': 'Test Chat 1'},
        {'thread_id': 'thread-2', 'title': 'Test Chat 2'},
      ],
      messages: [],
    );

    await pumpChatScreen(tester, mockState);
    await tester.pumpAndSettle();

    // Verify that the titles are rendered
    expect(find.text('Test Chat 1'), findsOneWidget);
    expect(find.text('Test Chat 2'), findsOneWidget);
  });

  testWidgets(
      'ChatScreen hides initial layout and settles at bottom without scrolling animation on history restore',
      (WidgetTester tester) async {
    final viewModel = await pumpChatScreen(
      tester,
      ChatState(threadId: 'thread-1', isLoadingHistory: true, messages: []),
    );
    await tester.pump();

    viewModel.setStateForTesting(
      ChatState(
        threadId: 'thread-1',
        isLoadingHistory: false,
        messages: buildLongHistory(),
      ),
    );
    await tester.pump();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);
    final hiddenOpacity = tester.widget<Opacity>(
      find.ancestor(of: listFinder, matching: find.byType(Opacity)).first,
    );
    expect(hiddenOpacity.opacity, 0.0);

    await tester.pumpAndSettle();

    final visibleOpacity = tester.widget<Opacity>(
      find.ancestor(of: listFinder, matching: find.byType(Opacity)).first,
    );
    expect(visibleOpacity.opacity, 1.0);
    final controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 0.5));
  });

  testWidgets(
      'ChatScreen restores saved non-bottom scroll offset within the same thread on refresh',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'last_active_thread_scroll_thread_id': 'thread-1',
      'last_active_thread_scroll_offset': 250.0,
      'last_active_thread_scroll_at_bottom': false,
    });

    final viewModel = await pumpChatScreen(
      tester,
      ChatState(threadId: 'thread-1', isLoadingHistory: true, messages: []),
    );
    await tester.pump();

    viewModel.setStateForTesting(
      ChatState(
        threadId: 'thread-1',
        isLoadingHistory: false,
        messages: buildLongHistory(),
      ),
    );
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    final controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(250.0));
    expect(controller.position.pixels, closeTo(250.0, 0.5));
  });

  testWidgets('ChatScreen shows capability starter chips only in empty state',
      (WidgetTester tester) async {
    final viewModel = await pumpChatScreen(
      tester,
      ChatState(messages: [], isLoadingHistory: false),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('starter-chip-graph')), findsOneWidget);
    expect(find.byKey(const Key('starter-chip-code')), findsOneWidget);
    expect(find.byKey(const Key('starter-chip-hybrid')), findsOneWidget);
    expect(
      find.text('Trace multi-hop connections in Knowledge Graph'),
      findsOneWidget,
    );
    expect(
      find.text('Analyze symbol blast radius with Code X-Ray'),
      findsOneWidget,
    );
    expect(
      find.text('Search live web & corpus with inline citations'),
      findsOneWidget,
    );

    viewModel.setStateForTesting(
      ChatState(
        threadId: 'thread-1',
        isLoadingHistory: false,
        messages: [ChatMessage(role: 'user', content: 'Hi')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('starter-chip-graph')), findsNothing);
  });

  testWidgets(
      'ChatSidebar collapses consecutive duplicate titles and expands on tap',
      (WidgetTester tester) async {
    await pumpChatScreen(
      tester,
      ChatState(
        pastThreads: [
          {'thread_id': 't1', 'title': 'Greeting Exchange'},
          {'thread_id': 't2', 'title': 'Greeting Exchange'},
          {'thread_id': 't3', 'title': 'Greeting Exchange'},
          {'thread_id': 't4', 'title': 'Other Thread'},
        ],
        messages: [],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Greeting Exchange'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget);
    expect(find.text('Other Thread'), findsOneWidget);

    await tester.tap(find.byKey(const Key('duplicate-group-toggle-t1')));
    await tester.pumpAndSettle();

    expect(find.text('Greeting Exchange'), findsNWidgets(3));
  });
}

class MockChatRepository extends Mock implements IChatRepository {
  @override
  Stream<Map<String, dynamic>> streamSyncEvents() => const Stream.empty();
}

class MockTTSRepository extends Mock implements TTSRepository {}

class MockMemoryRepository extends Mock implements MemoryRepository {}

class MockProjectRepository extends Mock implements ProjectRepository {}

class MockChatViewModel extends ChatViewModel {
  MockChatViewModel(ChatState initialState)
      : super(
            MockChatRepository(), MockTTSRepository(), MockMemoryRepository()) {
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
      {List<dynamic>? attachments,
      String? model,
      Map<String, dynamic>? codeScope,
      String? thinkingLevel}) async {
    return super.noSuchMethod(
      Invocation.method(#sendMessage, [
        text
      ], {
        #attachments: attachments,
        #model: model,
        #codeScope: codeScope,
        #thinkingLevel: thinkingLevel,
      }),
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
