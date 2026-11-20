import 'package:veraxi_app/core/local_ai/local_llm_engine.dart';
import 'package:veraxi_app/core/local_ai/local_vector_db.dart';
import 'package:veraxi_app/core/local_ai/local_embedding_engine.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class LocalChatDataSource {
  final LocalLlmEngine _llmEngine;
  final LocalVectorDb _vectorDb;
  final LocalEmbeddingEngine _embeddingEngine;

  LocalChatDataSource({
    required LocalLlmEngine llmEngine,
    required LocalVectorDb vectorDb,
    required LocalEmbeddingEngine embeddingEngine,
  })  : _llmEngine = llmEngine,
        _vectorDb = vectorDb,
        _embeddingEngine = embeddingEngine;

  static LocalChatDataSource forModel() {
    return LocalChatDataSource(
      llmEngine: LocalLlmEngine(),
      vectorDb: LocalVectorDb(),
      embeddingEngine: LocalEmbeddingEngine(),
    );
  }

  /// Exact total token count for [texts] under the model's own
  /// tokenizer (loads the model once). Null when the model file is
  /// missing or any count fails — callers fall back to estimates
  /// rather than fabricate.
  Future<int?> countTokensTotal(List<String> texts, String modelName) async {
    try {
      final appDocsDir = await getApplicationDocumentsDirectory();
      final modelPath = p.join(appDocsDir.path, modelName);
      if (!await File(modelPath).exists()) return null;
      await _llmEngine.loadModel(modelPath);
      var total = 0;
      for (final text in texts) {
        final count = await _llmEngine.countTokens(text);
        if (count == null) return null;
        total += count;
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  /// One-shot raw generation with the on-device model — used by
  /// local compaction to summarize a thread without any server.
  /// Throws when the model file is missing.
  Future<String> generateText(String prompt, String modelName) async {
    final appDocsDir = await getApplicationDocumentsDirectory();
    final modelPath = p.join(appDocsDir.path, modelName);
    if (!await File(modelPath).exists()) {
      throw StateError(
          'Model file $modelName not found on device. Download it from the Local API Key settings.');
    }
    await _llmEngine.loadModel(modelPath);
    final buffer = StringBuffer();
    await for (final chunk in _llmEngine.streamGenerate(prompt)) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  Stream<Map<String, dynamic>> streamChat(
      String question, String modelName) async* {
    final appDocsDir = await getApplicationDocumentsDirectory();
    final modelPath = p.join(appDocsDir.path, modelName);

    if (!await File(modelPath).exists()) {
      yield {
        'event': 'on_chat_model_stream',
        'data': {
          'chunk': {
            'content':
                'Error: Model file $modelName not found on device. Please download it from the Local API Key settings.'
          }
        }
      };
      return;
    }

    await _llmEngine.loadModel(modelPath);

    String contextText = '';
    try {
      // 1. Embed user question
      final queryVector = _embeddingEngine.getEmbedding(question);

      // 2. Search for relevant context
      final results = _vectorDb.searchSimilar(queryVector);
      contextText = results.map((r) => r.text).join('\n\n');
    } catch (_) {
      // Ignore if embedding model isn't loaded (e.g., local model testing)
    }

    // 3. Augment the prompt
    final prompt = '''
Use the following context to answer the user's question. If the context is empty or unhelpful, answer from your general knowledge.

Context:
$contextText

Question:
$question
''';

    // 4. Stream response back in the format expected by the app
    await for (final chunk in _llmEngine.streamGenerate(prompt)) {
      yield {
        'event': 'on_chat_model_stream',
        'data': {
          'chunk': {'content': chunk}
        }
      };
    }

    // 5. Report the engine's real usage when the binding surfaced
    // it, in the same metadata shape the cloud path uses, so the
    // message is saved with provider-style token metrics.
    final usage = _llmEngine.lastCompletionUsage;
    if (usage != null) {
      yield {
        'event': 'metadata',
        'data': {
          'metrics': {
            'prompt_tokens': usage.promptTokens,
            'completion_tokens': usage.completionTokens,
            'total_tokens': usage.promptTokens + usage.completionTokens,
          }
        }
      };
    }
  }
}
