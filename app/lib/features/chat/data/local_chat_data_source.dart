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

    // 1. Embed user question
    final queryVector = _embeddingEngine.getEmbedding(question);

    // 2. Search for relevant context
    final results = _vectorDb.searchSimilar(queryVector);
    final contextText = results.map((r) => r.text).join('\n\n');

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
  }
}
