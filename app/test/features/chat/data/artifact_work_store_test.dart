import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_store.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_sync_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';

/// In-memory sync fake: records saves, serves canned thread work,
/// and can be told to fail (the offline case).
class _FakeSync extends ArtifactWorkSyncRepository {
  _FakeSync() : super(ApiClient(baseUrl: 'https://unused.invalid'));

  Map<String, ArtifactWorkState> remote = {};
  final List<ArtifactWorkState> pushed = [];
  bool failFetch = false;

  @override
  Future<Map<String, ArtifactWorkState>> fetchThreadWork(
    String threadId,
  ) async {
    if (failFetch) throw Exception('offline');
    return remote;
  }

  @override
  Future<void> saveWork({
    required String threadId,
    required int messageIndex,
    required int artifactIndex,
    required ArtifactWorkState state,
  }) async {
    pushed.add(state);
    remote['$messageIndex:$artifactIndex'] = state;
  }
}

ArtifactWorkState _state(List<String> versions, {int updatedAtMs = 0}) {
  return ArtifactWorkState(
    versions: versions,
    versionIndex: versions.length - 1,
    originalCode: versions.first,
    updatedAtMs: updatedAtMs,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalChatDatabase db;

  setUp(() {
    db = LocalChatDatabase.withExecutor(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  ArtifactWorkStore localStore() => ArtifactWorkStore(database: db);

  /// Writes an entry straight into the local table with its stamp
  /// intact (store.save restamps, which seeded history must not).
  Future<void> seedLocal(String key, ArtifactWorkState state) async {
    await db.into(db.artifactWorkEntries).insert(
          ArtifactWorkEntriesCompanion.insert(
            workKey: key,
            stateJson: jsonEncode(state.toJson()),
            updatedAtMs: Value(state.updatedAtMs),
          ),
        );
  }

  group('artifactWorkKey', () {
    test('builds thread:message:block coordinates', () {
      expect(
        artifactWorkKey(threadId: 't1', messageIndex: 3, artifactIndex: 1),
        't1:3:1',
      );
      expect(
        artifactWorkKey(threadId: null, messageIndex: 0, artifactIndex: 0),
        'local:0:0',
      );
    });

    test('null without a message index', () {
      expect(
        artifactWorkKey(threadId: 't1', messageIndex: null, artifactIndex: 0),
        isNull,
      );
    });
  });

  group('ArtifactWorkStore', () {
    test('save/load round-trips versions and the published link', () async {
      final store = localStore();
      const state = ArtifactWorkState(
        versions: ['print("v1")', 'print("v2")'],
        versionIndex: 1,
        originalCode: 'print("v1")',
        publishedId: 'abc',
        publishedUrl: 'https://veraxi.me/a/abc',
        publishedCode: 'print("v2")',
      );

      await store.save('t1:0:0', state);
      final loaded = await store.load('t1:0:0');

      expect(loaded, isNotNull);
      expect(loaded!.versions, ['print("v1")', 'print("v2")']);
      expect(loaded.versionIndex, 1);
      expect(loaded.originalCode, 'print("v1")');
      expect(loaded.publishedId, 'abc');
      expect(loaded.publishedUrl, 'https://veraxi.me/a/abc');
      expect(loaded.publishedCode, 'print("v2")');
      expect(loaded.hasUserWork, isTrue);
    });

    test('a missing key loads as null', () async {
      expect(await localStore().load('nope:0:0'), isNull);
    });

    test('a single untouched version is not user work', () {
      const state = ArtifactWorkState(
        versions: ['print("v1")'],
        versionIndex: 0,
        originalCode: 'print("v1")',
      );
      expect(state.hasUserWork, isFalse);
    });

    test('a corrupt stored row loads as null instead of throwing', () async {
      await db.into(db.artifactWorkEntries).insert(
            ArtifactWorkEntriesCompanion.insert(
              workKey: 't1:0:0',
              stateJson: '{not json',
              updatedAtMs: const Value(0),
            ),
          );
      expect(await localStore().load('t1:0:0'), isNull);
    });

    test('entries are capped, evicting the oldest first', () async {
      final store = localStore();
      for (var i = 0; i < 105; i++) {
        await store.save(
          't:$i:0',
          ArtifactWorkState(
            versions: ['v$i'],
            versionIndex: 0,
            originalCode: 'v$i',
          ),
        );
      }
      expect(await store.load('t:0:0'), isNull);
      expect(await store.load('t:4:0'), isNull);
      expect(await store.load('t:5:0'), isNotNull);
      expect(await store.load('t:104:0'), isNotNull);
    });

    test('save reports how many entries it evicted', () async {
      final store = localStore();
      // Fill exactly to the cap: no evictions yet.
      for (var i = 0; i < ArtifactWorkStore.maxEntries; i++) {
        final evicted = await store.save(
          't:$i:0',
          ArtifactWorkState(
            versions: ['v$i'],
            versionIndex: 0,
            originalCode: 'v$i',
          ),
        );
        expect(evicted, 0);
      }
      // One more distinct artifact evicts exactly the oldest.
      final evicted = await store.save(
        't:new:0',
        const ArtifactWorkState(
          versions: ['new'],
          versionIndex: 0,
          originalCode: 'new',
        ),
      );
      expect(evicted, 1);
      expect(await store.load('t:0:0'), isNull);
      // Updating an existing entry evicts nothing.
      final updated = await store.save(
        't:new:0',
        const ArtifactWorkState(
          versions: ['new', 'newer'],
          versionIndex: 1,
          originalCode: 'new',
        ),
      );
      expect(updated, 0);
    });
  });

  group('ArtifactWorkStore sync', () {
    test('save stamps the state and pushes it to the backend', () async {
      final sync = _FakeSync();
      final store = ArtifactWorkStore(sync: sync, database: db);

      await store.save('t1:0:0', _state(['v1', 'v2']));
      // The push is fire-and-forget; let it land.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(sync.pushed, hasLength(1));
      expect(sync.pushed.single.versions, ['v1', 'v2']);
      expect(sync.pushed.single.updatedAtMs, greaterThan(0));
      final local = await localStore().load('t1:0:0');
      expect(local!.updatedAtMs, sync.pushed.single.updatedAtMs);
    });

    test('local newer than remote wins and is pushed up', () async {
      await seedLocal('t1:0:0', _state(['old', 'mine'], updatedAtMs: 3000));
      final sync = _FakeSync()
        ..remote = {
          '0:0': _state(['old', 'theirs'], updatedAtMs: 2000)
        };
      final store = ArtifactWorkStore(sync: sync, database: db);

      final loaded = await store.load('t1:0:0');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(loaded!.versions, ['old', 'mine']);
      expect(sync.pushed.single.versions, ['old', 'mine']);
    });

    test('remote newer than local wins and refreshes the cache', () async {
      await seedLocal('t1:0:0', _state(['old'], updatedAtMs: 1000));
      final sync = _FakeSync()
        ..remote = {
          '0:0': _state(['old', 'new'], updatedAtMs: 2000)
        };
      final store = ArtifactWorkStore(sync: sync, database: db);

      final loaded = await store.load('t1:0:0');
      expect(loaded!.versions, ['old', 'new']);
      expect(loaded.updatedAtMs, 2000);

      final cached = await localStore().load('t1:0:0');
      expect(cached!.versions, ['old', 'new']);
    });

    test('local work missing remotely is pushed up on load', () async {
      final sync = _FakeSync();
      final store = ArtifactWorkStore(sync: sync, database: db);
      await localStore().save('t1:0:0', _state(['v1', 'v2']));
      sync.pushed.clear();

      final loaded = await store.load('t1:0:0');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(loaded!.versions, ['v1', 'v2']);
      expect(sync.pushed, hasLength(1));
    });

    test('a failing fetch falls back to the local state', () async {
      final sync = _FakeSync()..failFetch = true;
      final store = ArtifactWorkStore(sync: sync, database: db);
      await localStore().save('t1:0:0', _state(['v1', 'v2']));

      final loaded = await store.load('t1:0:0');
      expect(loaded!.versions, ['v1', 'v2']);
    });

    test('the local pseudo-thread never syncs', () async {
      final sync = _FakeSync();
      final store = ArtifactWorkStore(sync: sync, database: db);

      await store.save('local:0:0', _state(['v1']));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(sync.pushed, isEmpty);
      expect((await store.load('local:0:0'))!.versions, ['v1']);
    });
  });

  group('parseWorkKey', () {
    test('parses coordinates, keeping colons in thread ids', () {
      expect(
        parseWorkKey('t1:3:1'),
        (threadId: 't1', messageIndex: 3, artifactIndex: 1),
      );
      expect(
        parseWorkKey('a:b:3:1'),
        (threadId: 'a:b', messageIndex: 3, artifactIndex: 1),
      );
    });

    test('rejects local and malformed keys', () {
      expect(parseWorkKey('local:0:0'), isNull);
      expect(parseWorkKey('t1:x:0'), isNull);
      expect(parseWorkKey('nocolons'), isNull);
    });
  });
}
