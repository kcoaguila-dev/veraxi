import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';

class LocalChatMigrationService {
  final ApiClient apiClient;
  LocalChatDatabase? _database;

  LocalChatMigrationService(
      {required this.apiClient, LocalChatDatabase? database})
      : _database = database;

  LocalChatDatabase get database => _database ??= LocalChatDatabase();

  Future<int> migrate() async {
    final threads = await _exportThreads();
    if (threads.isEmpty) return 0;

    final response = await apiClient.post(
      '/chat/threads/import',
      body: {'threads': threads},
    );
    return (response['imported'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> _exportThreads() async {
    final db = database;
    final threadRows = await (db.select(db.localThreads)
          ..orderBy([
            (thread) => OrderingTerm(
                expression: thread.timestamp, mode: OrderingMode.desc),
          ]))
        .get();

    if (threadRows.isEmpty) return const [];

    final allMessageRows = await (db.select(db.localMessages)
          ..orderBy([
            (message) => OrderingTerm(
                expression: message.timestamp, mode: OrderingMode.asc),
          ]))
        .get();

    final messagesByThread = <String, List<LocalMessage>>{};
    for (final msg in allMessageRows) {
      messagesByThread.putIfAbsent(msg.threadId, () => []).add(msg);
    }

    final exported = <Map<String, dynamic>>[];
    for (final thread in threadRows) {
      final messageRows = messagesByThread[thread.threadId] ?? const [];
      exported.add({
        'thread_id': thread.threadId,
        'title': thread.title,
        'is_pinned': thread.isPinned,
        'is_archived': thread.isArchived,
        'project_id': thread.projectId,
        'timestamp': thread.timestamp?.millisecondsSinceEpoch != null
            ? thread.timestamp!.millisecondsSinceEpoch / 1000
            : null,
        'messages': messageRows.map(_serializeMessage).toList(),
      });
    }
    return exported;
  }

  Map<String, dynamic> _serializeMessage(LocalMessage message) {
    return {
      'id': message.id,
      'role': message.role == 'user' ? 'user' : 'assistant',
      'content': message.content,
      'feedback': message.feedback,
      'model_name': message.modelName,
      'metrics': _decodeJson(message.metrics),
    };
  }

  dynamic _decodeJson(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return jsonDecode(value);
    } catch (_) {
      return null;
    }
  }
}
