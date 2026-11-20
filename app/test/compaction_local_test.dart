
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/compaction_local.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';
import 'package:veraxi_app/features/chat/data/local_chat_repository.dart';

class MockHttpClient extends Mock implements http.Client {}

Map<String, dynamic> msg(String role, String content,
        {List<dynamic>? toolEvents}) =>
    {
      'role': role,
      'content': content,
      if (toolEvents != null) 'toolEvents': toolEvents,
    };

List<Map<String, dynamic>> history(int turns) => [
      for (var i = 0; i < turns; i++) ...[
        msg('user', 'question $i ' * 20),
        msg('assistant', 'answer $i ' * 20),
      ],
    ];

void main() {
  group('splitLocalHistory', () {
    test('keeps the last N user turns verbatim', () {
      final (prefix, recent) = splitLocalHistory(history(6), 2);
      expect(prefix.length, 8);
      expect(recent.length, 4);
      expect(recent.first['content'], contains('question 4'));
    });

    test('too few turns compacts nothing', () {
      final (prefix, recent) = splitLocalHistory(history(2), 4);
      expect(prefix, isEmpty);
      expect(recent.length, 4);
    });
  });

  group('clearLocalToolResults', () {
    test('scrubs only prefix tool results and is idempotent', () {
      final messages = history(4);
      messages[1]['toolEvents'] = [
        {'id': 'a', 'name': 'search', 'result': 'big result ' * 30}
      ];
      messages[7]['toolEvents'] = [
        {'id': 'b', 'name': 'search', 'result': 'recent result'}
      ];
      final (cleared1, count1) = clearLocalToolResults(messages, 1);
      expect(count1, 1);
      final prefixEvent =
          (cleared1[1]['toolEvents'] as List).single as Map;
      expect(prefixEvent['result'], startsWith(kClearedToolPlaceholder));
      final recentEvent =
          (cleared1[7]['toolEvents'] as List).single as Map;
      expect(recentEvent['result'], 'recent result');
      final (_, count2) = clearLocalToolResults(cleared1, 1);
      expect(count2, 0);
    });
  });

  group('minimum progress', () {
    test('refuses trivial savings', () {
      expect(() => checkLocalMinProgress(1000, 950), throwsException);
      checkLocalMinProgress(1000, 800); // 20%: fine
    });
  });

  group('LocalChatRepository compaction', () {
    late LocalChatDatabase db;
    late LocalChatRepository repository;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});
      db = LocalChatDatabase.withExecutor(NativeDatabase.memory());
      repository = LocalChatRepository(
        apiClient: ApiClient(client: MockHttpClient(), baseUrl: 'http://t'),
        apiKeyStorage: ApiKeyStorage(),
        database: db,
      );
      await db.into(db.localThreads).insert(LocalThreadsCompanion.insert(
            threadId: 't1',
            title: 'Test',
            timestamp: Value(DateTime(2026, 1, 1)),
          ));
      final base = DateTime(2026, 1, 1, 12);
      for (var i = 0; i < 6; i++) {
        await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
              id: 'u$i',
              threadId: 't1',
              role: 'user',
              content: 'question $i ' * 30,
              timestamp: Value(base.add(Duration(minutes: i * 2))),
            ));
        await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
              id: 'a$i',
              threadId: 't1',
              role: 'assistant',
              content: 'answer $i ' * 30,
              timestamp: Value(base.add(Duration(minutes: i * 2 + 1))),
            ));
      }
    });

    tearDown(() async => db.close());

    test('apply replaces the prefix with a summary row, recent verbatim',
        () async {
      final result =
          await repository.applyCompaction('t1', summary: 'the summary');
      expect(result['messages_compacted'], 4);
      final after = await repository.getThreadHistory('t1');
      expect(after.length, 9); // summary + 4 kept turns
      expect(after.first['content'], startsWith(kSummaryPrefix));
      expect(after.first['content'], contains('the summary'));
      final metrics = after.first['metrics'] as Map;
      expect((metrics['compaction'] as Map)['messages_compacted'], 4);
      expect(after[1]['content'], contains('question 2'));
      expect(after.last['content'], contains('answer 5'));
    });

    test('apply refuses an empty summary and changes nothing', () async {
      await expectLater(
        repository.applyCompaction('t1', summary: '  '),
        throwsException,
      );
      final after = await repository.getThreadHistory('t1');
      expect(after.length, 12);
    });

    test('clearOldToolResults reports none when there are no tool events',
        () async {
      await expectLater(
        repository.clearOldToolResults('t1'),
        throwsA(predicate(
            (e) => e.toString().contains('No old tool results'))),
      );
    });
  });
}
