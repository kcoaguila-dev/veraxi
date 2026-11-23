import 'package:drift/drift.dart';

import 'connection/connection.dart';

part 'local_chat_database.g.dart';

class LocalThreads extends Table {
  TextColumn get threadId => text()();
  TextColumn get title => text()();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  TextColumn get projectId => text().nullable()();
  DateTimeColumn get timestamp => dateTime().nullable()();

  // Code Mode (Phase 1): which workspace the thread belongs to and
  // the repo/branch/source selection it is scoped to. Mirrors the
  // server-side thread_code_meta / thread_metadata fields.
  TextColumn get workspaceMode => text().withDefault(const Constant('chat'))();
  TextColumn get repoKey => text().nullable()();
  TextColumn get branch => text().nullable()();
  TextColumn get selectedSources => text().nullable()(); // JSON encoded

  @override
  Set<Column> get primaryKey => {threadId};
}

class LocalMessages extends Table {
  TextColumn get id => text()();
  TextColumn get threadId => text()();
  TextColumn get role => text()();
  TextColumn get content => text()();
  IntColumn get feedback => integer().withDefault(const Constant(0))();
  TextColumn get modelName => text().nullable()();
  TextColumn get metrics => text().nullable()(); // JSON encoded
  TextColumn get toolEvents => text().nullable()(); // JSON encoded
  TextColumn get activity => text().nullable()(); // JSON encoded activity steps
  TextColumn get reasoning => text().nullable()();
  RealColumn get reasoningDurationSeconds => real().nullable()();
  DateTimeColumn get timestamp => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One artifact's saved panel work (version history, published
/// link), keyed by its work-store coordinates
/// ("thread:message:artifact"). The local cache half of the
/// artifact work store; the synced copy lives server-side next to
/// the chat history.
class ArtifactWorkEntries extends Table {
  TextColumn get workKey => text()();
  TextColumn get stateJson => text()(); // JSON encoded ArtifactWorkState
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {workKey};
}

/// One key-value entry of an artifact's scoped runtime storage
/// (`window.veraxiStorage`), keyed by (scope, key). The local half
/// of the runtime storage repository; the synced copy lives
/// server-side under the same scope (see routes/artifacts.py).
class ArtifactRuntimeStorageEntries extends Table {
  TextColumn get scopeId => text()();
  TextColumn get entryKey => text()();
  TextColumn get entryValue => text()();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {scopeId, entryKey};
}

@DriftDatabase(tables: [
  LocalThreads,
  LocalMessages,
  ArtifactWorkEntries,
  ArtifactRuntimeStorageEntries,
])
class LocalChatDatabase extends _$LocalChatDatabase {
  LocalChatDatabase() : super(openConnection());

  /// Test seam: run against an in-memory / file executor instead of the
  /// on-device database file.
  LocalChatDatabase.withExecutor(super.executor);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) => m.createAll(),
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await m.addColumn(localMessages, localMessages.activity);
          }
          if (from < 3) {
            await m.addColumn(localMessages, localMessages.reasoning);
            await m.addColumn(
                localMessages, localMessages.reasoningDurationSeconds);
          }
          if (from < 4) {
            await m.createTable(artifactWorkEntries);
          }
          if (from < 5) {
            await m.createTable(artifactRuntimeStorageEntries);
          }
          if (from < 6) {
            await m.addColumn(localThreads, localThreads.workspaceMode);
            await m.addColumn(localThreads, localThreads.repoKey);
            await m.addColumn(localThreads, localThreads.branch);
            await m.addColumn(localThreads, localThreads.selectedSources);
          }
        },
      );
}
