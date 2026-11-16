import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';
import 'package:veraxi_app/features/chat/data/local_chat_migration_service.dart';
import 'package:veraxi_app/features/chat/data/local_chat_repository.dart';

class MockHttpClient extends Mock implements http.Client {}

class MockApiClient extends Mock implements ApiClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalChatDatabase db;
  late MockHttpClient mockHttpClient;
  late ApiClient apiClient;
  late LocalChatRepository repository;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = LocalChatDatabase.withExecutor(NativeDatabase.memory());
    mockHttpClient = MockHttpClient();
    apiClient = ApiClient(client: mockHttpClient, baseUrl: 'http://test.com');
    repository = LocalChatRepository(
      apiClient: apiClient,
      apiKeyStorage: ApiKeyStorage(),
      database: db,
    );
    registerFallbackValue(http.Request('POST', Uri.parse('http://test.com')));
  });

  tearDown(() async {
    await db.close();
  });

  void stubSseStream(String body) {
    when(() => mockHttpClient.send(any())).thenAnswer(
      (_) async => http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
      ),
    );
  }

  test('streamChat persists reasoning and getThreadHistory returns it',
      () async {
    stubSseStream([
      'data: ${jsonEncode({
            'event': 'on_reasoning_stream',
            'data': {'text': 'deep '}
          })}',
      '',
      'data: ${jsonEncode({
            'event': 'on_reasoning_stream',
            'data': {'text': 'thought'}
          })}',
      '',
      'data: ${jsonEncode({
            'event': 'on_reasoning_end',
            'data': {'seconds': 4.2}
          })}',
      '',
      'data: ${jsonEncode({
            'event': 'on_chat_model_stream',
            'data': {
              'chunk': {'content': 'Final answer'}
            }
          })}',
      '',
      'data: [DONE]',
      '',
    ].join('\n'));

    final events = await repository
        .streamChat('Hello?', threadId: 'thread-1', model: 'test-model')
        .toList();
    expect(events, isNotEmpty);

    final history = await repository.getThreadHistory('thread-1');
    final assistant = history.firstWhere((m) => m['role'] == 'assistant');
    expect(assistant['content'], 'Final answer');
    expect(assistant['reasoning'], 'deep thought');
    expect(assistant['reasoning_duration_seconds'], 4.2);
  });

  test('streamChat without reasoning stores null reasoning fields', () async {
    stubSseStream([
      'data: ${jsonEncode({
            'event': 'on_chat_model_stream',
            'data': {
              'chunk': {'content': 'Plain answer'}
            }
          })}',
      '',
      'data: [DONE]',
      '',
    ].join('\n'));

    await repository
        .streamChat('Hi', threadId: 'thread-2', model: 'test-model')
        .toList();

    final history = await repository.getThreadHistory('thread-2');
    final assistant = history.firstWhere((m) => m['role'] == 'assistant');
    expect(assistant['reasoning'], isNull);
    expect(assistant['reasoning_duration_seconds'], isNull);
  });

  test('migration export includes reasoning fields', () async {
    await db.into(db.localThreads).insert(LocalThreadsCompanion.insert(
          threadId: 'thread-1',
          title: 'Chat',
          timestamp: const Value(null),
        ));
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          id: 'assistant-1',
          threadId: 'thread-1',
          role: 'assistant',
          content: 'Final answer',
          reasoning: const Value('deep thought'),
          reasoningDurationSeconds: const Value(4.2),
        ));

    final mockApiClient = MockApiClient();
    Map<String, dynamic>? capturedBody;
    when(() => mockApiClient.post('/chat/threads/import',
        body: any(named: 'body'))).thenAnswer((invocation) async {
      capturedBody = invocation.namedArguments[#body] as Map<String, dynamic>?;
      return {'imported': 1};
    });

    final service =
        LocalChatMigrationService(apiClient: mockApiClient, database: db);
    final imported = await service.migrate();

    expect(imported, 1);
    final threads = capturedBody!['threads'] as List<dynamic>;
    final message = (threads.single as Map<String, dynamic>)['messages'].single
        as Map<String, dynamic>;
    expect(message['reasoning'], 'deep thought');
    expect(message['reasoning_duration_seconds'], 4.2);
  });
}
