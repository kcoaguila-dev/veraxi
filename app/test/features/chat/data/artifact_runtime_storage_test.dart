import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:veraxi_app/features/chat/data/artifact_runtime_storage_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_runtime_storage_provider.dart';

void main() {
  group('ArtifactRuntimeStorageRepository (in-memory local)', () {
    late ArtifactRuntimeStorageRepository repo;
    setUp(() {
      repo = ArtifactRuntimeStorageRepository(
        local: InMemoryArtifactRuntimeLocalStore(),
      );
    });

    test('set/get/delete/list round trip, scoped per artifact', () async {
      await repo.set('t:0:0', 'name', 'Ada');
      await repo.set('t:0:0', 'count', '3');
      await repo.set('t:0:1', 'name', 'Other');
      expect(await repo.get('t:0:0', 'name'), 'Ada');
      expect(await repo.get('t:0:0', 'missing'), isNull);
      expect(await repo.list('t:0:0'), ['count', 'name']);
      expect(await repo.list('t:0:0', prefix: 'na'), ['name']);
      await repo.delete('t:0:0', 'name');
      expect(await repo.get('t:0:0', 'name'), isNull);
      expect(await repo.get('t:0:1', 'name'), 'Other');
    });

    test('value over the cap is rejected', () async {
      expect(
        () => repo.set('s', 'k', 'x' * (maxStorageValueChars + 1)),
        throwsA(isA<ArtifactStorageLimitException>()),
      );
    });

    test('key-count cap is enforced, updates still allowed', () async {
      for (var i = 0; i < maxStorageKeysPerScope; i++) {
        await repo.set('s', 'k$i', 'v');
      }
      expect(
        () => repo.set('s', 'one-more', 'v'),
        throwsA(isA<ArtifactStorageLimitException>()),
      );
      await repo.set('s', 'k0', 'v2');
      expect(await repo.get('s', 'k0'), 'v2');
    });
  });

  group('ArtifactStorageBridge validation', () {
    late ArtifactStorageBridge bridge;
    setUp(() {
      bridge = ArtifactStorageBridge(
        repository: ArtifactRuntimeStorageRepository(
          local: InMemoryArtifactRuntimeLocalStore(),
        ),
        scopeId: 't:0:0',
      );
    });

    Map<String, dynamic> msg(Map<String, dynamic> extra) => {
          'type': 'veraxi_storage',
          'requestId': 'r1',
          ...extra,
        };

    test('handles a full get/set/list/delete conversation', () async {
      var reply =
          await bridge.handle(msg({'op': 'set', 'key': 'a', 'value': 'hello'}));
      expect(reply['ok'], isTrue);
      expect(reply['type'], 'veraxi_storage_reply');
      expect(reply['requestId'], 'r1');
      reply = await bridge.handle(msg({'op': 'get', 'key': 'a'}));
      expect(reply['data'], 'hello');
      reply = await bridge.handle(msg({'op': 'list', 'key': ''}));
      expect(reply['data'], ['a']);
      reply = await bridge.handle(msg({'op': 'delete', 'key': 'a'}));
      expect(reply['ok'], isTrue);
      reply = await bridge.handle(msg({'op': 'get', 'key': 'a'}));
      expect(reply['data'], isNull);
    });

    test('accepts a JSON string message (the web postMessage shape)', () async {
      final reply = await bridge.handle(
        '{"type":"veraxi_storage","requestId":"r9","op":"set",'
        '"key":"a","value":"b"}',
      );
      expect(reply['ok'], isTrue);
      expect(reply['requestId'], 'r9');
    });

    test('rejects malformed messages without throwing', () async {
      for (final raw in [
        'not json',
        {'type': 'other', 'requestId': 'r', 'op': 'get', 'key': 'a'},
        {'type': 'veraxi_storage', 'requestId': '', 'op': 'get', 'key': 'a'},
        {'type': 'veraxi_storage', 'requestId': 'r', 'op': 'nuke', 'key': 'a'},
        {'type': 'veraxi_storage', 'requestId': 'r', 'op': 'get'},
        {'type': 'veraxi_storage', 'requestId': 'r', 'op': 'set', 'key': 'a'},
        {
          'type': 'veraxi_storage',
          'requestId': 'r',
          'op': 'set',
          'key': 'a',
          'value': 42,
        },
      ]) {
        final reply = await bridge.handle(raw);
        expect(reply['ok'], isFalse, reason: '$raw');
        expect(reply['error'], isNotNull);
      }
    });
  });

  group('Drift local store + schema migration', () {
    test('runtime storage entries persist in the Drift table', () async {
      final db = LocalChatDatabase.withExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DriftArtifactRuntimeLocalStore(database: db);
      await store.put('t:0:0', 'k', 'v');
      await store.put('t:0:0', 'k2', 'v2');
      await store.put('other:0:0', 'k', 'other');
      expect(await store.entriesForScope('t:0:0'), {'k': 'v', 'k2': 'v2'});
      await store.remove('t:0:0', 'k');
      expect(await store.entriesForScope('t:0:0'), {'k2': 'v2'});
    });

    test('schema is 6 and a v4 database upgrades cleanly', () async {
      final dir = await Directory.systemTemp.createTemp('veraxi_mig_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/chat.sqlite');

      // Build a v4-shaped database by hand: the three v4 tables
      // and user_version = 4, with one work entry that must survive.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE local_threads (
          thread_id TEXT NOT NULL PRIMARY KEY,
          title TEXT NOT NULL,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          is_archived INTEGER NOT NULL DEFAULT 0,
          project_id TEXT NULL,
          timestamp INTEGER NULL
        );
        CREATE TABLE local_messages (
          id TEXT NOT NULL PRIMARY KEY,
          thread_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          feedback INTEGER NOT NULL DEFAULT 0,
          model_name TEXT NULL,
          metrics TEXT NULL,
          tool_events TEXT NULL,
          activity TEXT NULL,
          reasoning TEXT NULL,
          reasoning_duration_seconds REAL NULL,
          timestamp INTEGER NULL
        );
        CREATE TABLE artifact_work_entries (
          work_key TEXT NOT NULL PRIMARY KEY,
          state_json TEXT NOT NULL,
          updated_at_ms INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO artifact_work_entries VALUES ('t:0:0', '{}', 1);
        PRAGMA user_version = 4;
      ''');
      raw.close();

      final db = LocalChatDatabase.withExecutor(NativeDatabase(file));
      addTearDown(db.close);
      expect(db.schemaVersion, 6);
      // The upgrade created the runtime-storage table and it works.
      final store = DriftArtifactRuntimeLocalStore(database: db);
      await store.put('t:0:0', 'k', 'v');
      expect(await store.entriesForScope('t:0:0'), {'k': 'v'});
      // Pre-existing v4 work survived the upgrade.
      final work = await db.select(db.artifactWorkEntries).get();
      expect(work, hasLength(1));
      expect(work.single.workKey, 't:0:0');
    });

    test('a v5 database upgrades to v6 with Code Mode columns', () async {
      final dir = await Directory.systemTemp.createTemp('veraxi_mig_v6_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/chat.sqlite');

      // Build a v5-shaped database by hand: the v4 tables plus the
      // v5 runtime-storage table and user_version = 5, with one
      // thread row that must survive with default Code Mode values.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE local_threads (
          thread_id TEXT NOT NULL PRIMARY KEY,
          title TEXT NOT NULL,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          is_archived INTEGER NOT NULL DEFAULT 0,
          project_id TEXT NULL,
          timestamp INTEGER NULL
        );
        CREATE TABLE local_messages (
          id TEXT NOT NULL PRIMARY KEY,
          thread_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          feedback INTEGER NOT NULL DEFAULT 0,
          model_name TEXT NULL,
          metrics TEXT NULL,
          tool_events TEXT NULL,
          activity TEXT NULL,
          reasoning TEXT NULL,
          reasoning_duration_seconds REAL NULL,
          timestamp INTEGER NULL
        );
        CREATE TABLE artifact_work_entries (
          work_key TEXT NOT NULL PRIMARY KEY,
          state_json TEXT NOT NULL,
          updated_at_ms INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE artifact_runtime_storage_entries (
          scope_id TEXT NOT NULL,
          entry_key TEXT NOT NULL,
          entry_value TEXT NOT NULL,
          updated_at_ms INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (scope_id, entry_key)
        );
        INSERT INTO local_threads VALUES ('thread-1', 'Hello', 0, 0, NULL, NULL);
        PRAGMA user_version = 5;
      ''');
      raw.close();

      final db = LocalChatDatabase.withExecutor(NativeDatabase(file));
      addTearDown(db.close);
      expect(db.schemaVersion, 6);
      // The v6 upgrade added the Code Mode columns to local_threads
      // and the pre-existing thread reads back with valid defaults.
      final threads = await db.select(db.localThreads).get();
      expect(threads, hasLength(1));
      expect(threads.single.threadId, 'thread-1');
      expect(threads.single.workspaceMode, 'chat');
      expect(threads.single.repoKey, isNull);
      expect(threads.single.branch, isNull);
      expect(threads.single.selectedSources, isNull);
      // The new columns are writable after the upgrade.
      await (db.update(db.localThreads)
            ..where((t) => t.threadId.equals('thread-1')))
          .write(const LocalThreadsCompanion(
        workspaceMode: Value('code'),
        repoKey: Value('veraxi/custom-service'),
        branch: Value('main'),
        selectedSources: Value('["arch.pdf"]'),
      ));
      final updated = await db.select(db.localThreads).getSingle();
      expect(updated.workspaceMode, 'code');
      expect(updated.repoKey, 'veraxi/custom-service');
      expect(updated.branch, 'main');
      expect(updated.selectedSources, '["arch.pdf"]');
    });
  });
}
