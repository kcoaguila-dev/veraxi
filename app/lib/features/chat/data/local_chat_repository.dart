import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/data/compaction_local.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';
import 'package:uuid/uuid.dart';
import 'package:veraxi_app/features/chat/data/local_chat_data_source.dart'
    if (dart.library.html) 'package:veraxi_app/features/chat/data/local_chat_data_source_web.dart';

class LocalChatRepository implements IChatRepository {
  final ApiClient apiClient;
  final ApiKeyStorage apiKeyStorage;
  final LocalChatDatabase db;
  final _uuid = const Uuid();

  LocalChatRepository(
      {required this.apiClient,
      required this.apiKeyStorage,
      LocalChatDatabase? database})
      : db = database ?? LocalChatDatabase();

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
              'activity': m.activity != null ? jsonDecode(m.activity!) : [],
              'reasoning': m.reasoning,
              'reasoning_duration_seconds': m.reasoningDurationSeconds,
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
    final activity = <Map<String, dynamic>>[];
    final reasoningBuffer = StringBuffer();
    double? reasoningDurationSeconds;
    final aiMessageId = _uuid.v4();

    if (!isTemporary) {
      yield {
        'event': 'metadata',
        'data': {'thread_id': effectiveThreadId}
      };
    }

    await for (final event in stream) {
      if (event['event'] == 'on_reasoning_stream') {
        final text = event['data']?['text'];
        if (text is String) {
          reasoningBuffer.write(text);
        }
      } else if (event['event'] == 'on_reasoning_end') {
        final seconds = event['data']?['seconds'];
        if (seconds is num) {
          reasoningDurationSeconds = seconds.toDouble();
        }
      } else if (event['event'] == 'on_chat_model_stream') {
        final chunk = event['data']?['chunk']?['content'];
        if (chunk != null) {
          aiResponseContent += chunk;
        }
      } else if (event['event'] == 'on_step_start') {
        activity.add({
          'number': (event['step'] as num?)?.toInt() ?? activity.length + 1,
          'name': event['name'] ?? 'Activity',
          'description': event['description'] ?? '',
          'status': 'running',
          'toolEvents': <Map<String, dynamic>>[],
        });
      } else if (event['event'] == 'on_tool_start' ||
          event['event'] == 'on_tool_end') {
        toolEvents.add(event); // Simplistic tracking for local storage
        if (activity.isNotEmpty && event['event'] == 'on_tool_start') {
          final tools =
              activity.last['toolEvents'] as List<Map<String, dynamic>>;
          tools.add({
            'id': event['run_id'] ?? '',
            'name': event['name'] ?? 'tool',
            'args': event['data']?['input'] ?? {},
            'isComplete': false,
          });
        }
        if (activity.isNotEmpty && event['event'] == 'on_tool_end') {
          final runId = event['run_id'];
          for (final step in activity) {
            final tools = step['toolEvents'] as List<Map<String, dynamic>>;
            for (final tool in tools) {
              if (tool['id'] == runId) {
                tool
                  ..['isComplete'] = true
                  ..['result'] =
                      event['data']?['artifact'] ?? event['data']?['output']
                  ..['durationMs'] = event['duration_ms']
                  ..['summary'] = event['summary'];
                if (event['status'] == 'error') step['status'] = 'error';
              }
            }
          }
        }
      } else if (event['event'] == 'metadata' &&
          event['data']?['metrics'] != null) {
        finalMetrics = event['data']['metrics'];
      }
      yield event;
    }

    for (final step in activity) {
      if (step['status'] == 'running') step['status'] = 'complete';
    }

    if (!isTemporary) {
      finalMetrics ??= {};
      finalMetrics['response_at'] = DateTime.now().toUtc().toIso8601String();
      // Save AI Message when done
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            id: aiMessageId,
            threadId: effectiveThreadId,
            role: 'assistant',
            content: aiResponseContent,
            modelName: Value(model),
            metrics: Value(jsonEncode(finalMetrics)),
            toolEvents: Value(jsonEncode(toolEvents)),
            activity: Value(jsonEncode(activity)),
            reasoning: Value(
                reasoningBuffer.isEmpty ? null : reasoningBuffer.toString()),
            reasoningDurationSeconds: Value(reasoningDurationSeconds),
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
  Future<Map<String, dynamic>> confirmToolCall({
    required String toolName,
    required Map<String, dynamic> args,
    required bool approve,
  }) async {
    // Local/guest mode still reaches the same backend endpoint: the
    // gated tool executes server-side with the tenant's stored tokens.
    final data = await apiClient.post('/chat/confirm-tool', body: {
      'tool_name': toolName,
      'args': args,
      'approve': approve,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> getIntegrations() async {
    final data = await apiClient.get('/integrations');
    final list = data['integrations'] as List<dynamic>? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  @override
  Future<void> editMessage(
      String messageId, String content, String threadId) async {
    await (db.update(db.localMessages)..where((m) => m.id.equals(messageId)))
        .write(LocalMessagesCompanion(content: Value(content)));
  }

  /// Token total for a local history: EXACT counts from the loaded
  /// model's own tokenizer when a .gguf model is available (the
  /// second element reports whether the total is exact), otherwise
  /// the chars/4 estimate. Never fabricates: exactness is reported,
  /// not assumed.
  Future<(int, bool)> _historyTokens(
      List<Map<String, dynamic>> messages, String? model) async {
    if (model != null && model.endsWith('.gguf')) {
      final texts = <String>[];
      for (final message in messages) {
        texts.add(message['content'] as String? ?? '');
        final toolEvents = message['toolEvents'];
        if (toolEvents is List) {
          for (final event in toolEvents) {
            if (event is Map && event['result'] is String) {
              texts.add(event['result'] as String);
            }
          }
        }
      }
      final exact = await LocalChatDataSource.forModel()
          .countTokensTotal(texts, model);
      if (exact != null) return (exact, true);
    }
    return (estimateHistoryTokens(messages), false);
  }

  @override
  Future<Map<String, dynamic>> previewCompaction(String threadId,
      {String? model, int keepRecentTurns = 4, String? focus}) async {
    final history = await getThreadHistory(threadId);
    final (prefix, recent) = splitLocalHistory(history, keepRecentTurns);
    if (prefix.isEmpty) {
      throw Exception('Nothing old enough to compact yet.');
    }
    if (model == null || !model.endsWith('.gguf')) {
      throw Exception(
          'On-device compaction needs a local (.gguf) model selected.');
    }
    final prompt = buildLocalCompactionPrompt(prefix, focus);
    final summary =
        (await LocalChatDataSource.forModel().generateText(prompt, model))
            .trim();
    if (summary.isEmpty) {
      throw Exception('The model returned an empty summary.');
    }
    final (tokensBefore, exact) = await _historyTokens(history, model);
    final (tokensAfter, _) = await _historyTokens([
      {'role': 'user', 'content': buildLocalSummaryContent(summary)},
      ...recent,
    ], model);
    checkLocalMinProgress(tokensBefore, tokensAfter);
    return {
      'summary': summary,
      'messages_compacted': prefix.length,
      'tokens_before': tokensBefore,
      'tokens_after_estimate': tokensAfter,
      'estimated': !exact,
    };
  }

  @override
  Future<Map<String, dynamic>> applyCompaction(String threadId,
      {required String summary, int keepRecentTurns = 4, String? model}) async {
    if (summary.trim().isEmpty) {
      throw Exception('Summary is empty — nothing to apply.');
    }
    final history = await getThreadHistory(threadId);
    final (prefix, recent) = splitLocalHistory(history, keepRecentTurns);
    if (prefix.isEmpty) {
      throw Exception('Nothing old enough to compact yet.');
    }
    final (tokensBefore, exact) = await _historyTokens(history, model);
    final summaryContent = buildLocalSummaryContent(summary);
    final (tokensAfter, _) = await _historyTokens([
      {'role': 'user', 'content': summaryContent},
      ...recent,
    ], model);
    // Gate BEFORE mutating anything.
    checkLocalMinProgress(tokensBefore, tokensAfter);

    final prefixIds = prefix.map((m) => m['id'] as String).toList();
    await (db.delete(db.localMessages)
          ..where((m) => m.id.isIn(prefixIds)))
        .go();

    // The summary sorts just before the first kept message.
    DateTime summaryTimestamp = DateTime.now();
    if (recent.isNotEmpty) {
      final firstRecent = await (db.select(db.localMessages)
            ..where((m) => m.id.equals(recent.first['id'] as String)))
          .getSingleOrNull();
      if (firstRecent?.timestamp != null) {
        summaryTimestamp =
            firstRecent!.timestamp!.subtract(const Duration(milliseconds: 1));
      }
    }
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          id: _uuid.v4(),
          threadId: threadId,
          role: 'user',
          content: summaryContent,
          metrics: Value(jsonEncode(localCompactionRecord(
              prefix.length, tokensBefore,
              estimated: !exact))),
          timestamp: Value(summaryTimestamp),
        ));
    return {
      'status': 'ok',
      'messages_compacted': prefix.length,
      'tokens_after_estimate': tokensAfter,
      'estimated': !exact,
    };
  }

  @override
  Future<Map<String, dynamic>> clearOldToolResults(String threadId,
      {int keepRecentTurns = 4, String? model}) async {
    final history = await getThreadHistory(threadId);
    final (newHistory, cleared) =
        clearLocalToolResults(history, keepRecentTurns);
    if (cleared == 0) {
      throw Exception('No old tool results to clear.');
    }
    final (prefix, _) = splitLocalHistory(history, keepRecentTurns);
    for (var i = 0; i < prefix.length; i++) {
      final before = prefix[i];
      final after = newHistory[i];
      if (after['toolEvents'] != before['toolEvents']) {
        await (db.update(db.localMessages)
              ..where((m) => m.id.equals(before['id'] as String)))
            .write(LocalMessagesCompanion(
                toolEvents: Value(jsonEncode(after['toolEvents']))));
      }
    }
    final (tokensAfter, exact) = await _historyTokens(newHistory, model);
    return {
      'status': 'ok',
      'tool_results_cleared': cleared,
      'tokens_after_estimate': tokensAfter,
      'estimated': !exact,
    };
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
            activity: Value(m.activity),
            reasoning: Value(m.reasoning),
            reasoningDurationSeconds: Value(m.reasoningDurationSeconds),
            timestamp: Value(m.timestamp),
          ));
    }

    return newThreadId;
  }

  @override
  Future<String> shareThread(String threadId) async {
    return "local_share_not_supported";
  }

  @override
  Stream<Map<String, dynamic>> streamSyncEvents() async* {
    // Local mode does not support cross-device realtime sync.
    // We just return an empty stream that never emits.
    yield* const Stream.empty();
  }
}
