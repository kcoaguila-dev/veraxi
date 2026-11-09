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
  DateTimeColumn get timestamp => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [LocalThreads, LocalMessages])
class LocalChatDatabase extends _$LocalChatDatabase {
  LocalChatDatabase() : super(openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) => m.createAll(),
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await m.addColumn(localMessages, localMessages.activity);
          }
        },
      );
}
