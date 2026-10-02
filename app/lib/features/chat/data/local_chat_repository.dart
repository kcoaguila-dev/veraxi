import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';
import 'package:uuid/uuid.dart';
import 'package:veraxi_app/features/chat/data/local_chat_data_source.dart'
    if (dart.library.html) 'package:veraxi_app/features/chat/data/local_chat_data_source_web.dart';

class LocalChatRepository implements IChatRepository {
  final ApiClient apiClient;
  final ApiKeyStorage apiKeyStorage;
  final LocalChatDatabase db;
  final _uuid = const Uuid();

  LocalChatRepository({required this.apiClient, required this.apiKeyStorage})
      : db = LocalChatDatabase();

  @override
  Future<void> assignThreadToProject(String threadId, String? projectId) async {
    await db.update(db.localThreads)
      ..where((t) => t.threadId.equals(threadId))
      ..write(LocalThreadsCompanion(projectId: Value(projectId)));
  }

  @override
  Future<List<Map<String, dynamic>>> getThreads() async {
    final query = db.select(db.localThreads)
      ..orderBy([
        (t) => OrderingTerm(expression: t.timestamp, mode: OrderingMode.desc)
      ]);
    final threads = await query.get();

    return threads
        .map((t) => {
              'thread_id': t.threadId,
              'title': t.title,
              'is_pinned': t.isPinned,
              'is_archived': t.isArchived,
              'project_id': t.projectId,
            })
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getThreadHistory(String threadId) async {
    final query = db.select(db.localMessages)
      ..where((m) => m.threadId.equals(threadId))
      ..orderBy([
        (m) => OrderingTerm(expression: m.timestamp, mode: OrderingMode.asc)
      ]);
    final messages = await query.get();

    return messages
        .map((m) => {
              'id': m.id,
              'role': m.role,
              'content': m.content,
              'feedback': m.feedback,
              'model_name': m.modelName,
              'metrics': m.metrics != null ? jsonDecode(m.metrics!) : null,
              'toolEvents':
                  m.toolEvents != null ? jsonDecode(m.toolEvents!) : [],
            })
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getSharedThreadHistory(
      String threadId) async {
    return []; // Sharing not supported in pure local mode
  }

  @override
  Stream<Map<String, dynamic>> streamChat(String question,
      {String? threadId,
      bool isTemporary = false,
      String? model,
      bool calculateGrounding = true,
      Map<String, dynamic>? toolSettings}) async* {
    final effectiveThreadId = threadId ?? _uuid.v4();

    if (!isTemporary) {
      // Create thread if it doesn't exist
      final threadExists = await (db.select(db.localThreads)
            ..where((t) => t.threadId.equals(effectiveThreadId)))
          .getSingleOrNull();
      if (threadExists == null) {
        final title =
            question.length > 40 ? '${question.substring(0, 40)}...' : question;
        await db.into(db.localThreads).insert(LocalThreadsCompanion.insert(
              threadId: effectiveThreadId,
              title: title,
              timestamp: Value(DateTime.now()),
            ));
      } else {
        await (db.update(db.localThreads)
              ..where((t) => t.threadId.equals(effectiveThreadId)))
            .write(LocalThreadsCompanion(timestamp: Value(DateTime.now())));
      }

      // Save User Message
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            id: _uuid.v4(),
            threadId: effectiveThreadId,
            role: 'user',
            content: question,
            timestamp: Value(DateTime.now()),
          ));
    }

    Stream<Map<String, dynamic>> stream;
    if (model != null && model.endsWith('.gguf')) {
      final localDataSource = LocalChatDataSource.forModel();
      stream = localDataSource.streamChat(question, model);
    } else {
      final cloudRepo = CloudChatRepository(
          apiClient: apiClient, apiKeyStorage: apiKeyStorage);
      stream = cloudRepo.streamChat(
        question,
        threadId: effectiveThreadId,
        isTemporary: true, // Force backend to not save
        model: model,
        calculateGrounding: calculateGrounding,
        toolSettings: toolSettings,
      );
    }

    String aiResponseContent = '';
    Map<String, dynamic>? finalMetrics;
    List<dynamic> toolEvents = [];
    final aiMessageId = _uuid.v4();

    if (!isTemporary) {
      yield {
        'event': 'metadata',
        'data': {'thread_id': effectiveThreadId}
      };
    }

    await for (final event in stream) {
      if (event['event'] == 'on_chat_model_stream') {
        final chunk = event['data']?['chunk']?['content'];
        if (chunk != null) {
          aiResponseContent += chunk;
        }
      } else if (event['event'] == 'on_tool_start' ||
          event['event'] == 'on_tool_end') {
        toolEvents.add(event); // Simplistic tracking for local storage
      } else if (event['event'] == 'metadata' &&
          event['data']?['metrics'] != null) {
        finalMetrics = event['data']['metrics'];
      }
      yield event;
    }

    if (!isTemporary) {
      // Save AI Message when done
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            id: aiMessageId,
            threadId: effectiveThreadId,
            role: 'assistant',
            content: aiResponseContent,
            modelName: Value(model),
            metrics:
                Value(finalMetrics != null ? jsonEncode(finalMetrics) : null),
            toolEvents: Value(jsonEncode(toolEvents)),
            timestamp: Value(DateTime.now()),
          ));
    }
  }

  @override
  Future<String> uploadAttachment(List<int> fileBytes, String fileName) async {
    final cloudRepo =
        CloudChatRepository(apiClient: apiClient, apiKeyStorage: apiKeyStorage);
    return cloudRepo.uploadAttachment(fileBytes,
        fileName); // Uses backend parser which is fine for local mode
  }

  @override
  Future<void> submitFeedback(String messageId, int value) async {
    await (db.update(db.localMessages)..where((m) => m.id.equals(messageId)))
        .write(LocalMessagesCompanion(feedback: Value(value)));
  }

  @override
  Future<void> editMessage(
      String messageId, String content, String threadId) async {
    await (db.update(db.localMessages)..where((m) => m.id.equals(messageId)))
        .write(LocalMessagesCompanion(content: Value(content)));
  }

  @override
  Future<void> regenerateResponse(String threadId) async {
    // Regenerate not fully supported locally yet, requires deleting last AI message and re-running stream
  }

  @override
  Future<void> renameThread(String threadId, String newTitle) async {
    await (db.update(db.localThreads)
          ..where((t) => t.threadId.equals(threadId)))
        .write(LocalThreadsCompanion(title: Value(newTitle)));
  }

  @override
  Future<void> togglePinThread(String threadId) async {
    final thread = await (db.select(db.localThreads)
          ..where((t) => t.threadId.equals(threadId)))
        .getSingle();
    await (db.update(db.localThreads)
          ..where((t) => t.threadId.equals(threadId)))
        .write(LocalThreadsCompanion(isPinned: Value(!thread.isPinned)));
  }

  @override
  Future<void> toggleArchiveThread(String threadId) async {
    final thread = await (db.select(db.localThreads)
          ..where((t) => t.threadId.equals(threadId)))
        .getSingle();
    await (db.update(db.localThreads)
          ..where((t) => t.threadId.equals(threadId)))
        .write(LocalThreadsCompanion(isArchived: Value(!thread.isArchived)));
  }

  @override
  Future<void> deleteThread(String threadId) async {
    await (db.delete(db.localThreads)
          ..where((t) => t.threadId.equals(threadId)))
        .go();
    await (db.delete(db.localMessages)
          ..where((m) => m.threadId.equals(threadId)))
        .go();
  }

  @override
  Future<void> deleteAllThreads() async {
    await db.delete(db.localThreads).go();
    await db.delete(db.localMessages).go();
  }

  @override
  Future<String> duplicateThread(String threadId) async {
    final newThreadId = _uuid.v4();
    final thread = await (db.select(db.localThreads)
          ..where((t) => t.threadId.equals(threadId)))
        .getSingle();

    await db.into(db.localThreads).insert(LocalThreadsCompanion.insert(
          threadId: newThreadId,
          title: '${thread.title} (Copy)',
          timestamp: Value(DateTime.now()),
        ));

    final messages = await (db.select(db.localMessages)
          ..where((m) => m.threadId.equals(threadId)))
        .get();
    for (var m in messages) {
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            id: _uuid.v4(),
            threadId: newThreadId,
            role: m.role,
            content: m.content,
            modelName: Value(m.modelName),
            metrics: Value(m.metrics),
            toolEvents: Value(m.toolEvents),
            timestamp: Value(m.timestamp),
          ));
    }

    return newThreadId;
  }

  @override
  Future<String> shareThread(String threadId) async {
    return "local_share_not_supported";
  }
}
