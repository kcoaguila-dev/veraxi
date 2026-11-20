import 'dart:async';
import 'package:fllama/fllama.dart';

/// Normalize a llama.cpp-binding completion result into provider-style
/// usage counts. The bindings are modelled on llama-server, whose
/// completion result carries `tokens_evaluated` (prompt tokens
/// processed) and `tokens_predicted` (generated tokens), with a
/// `timings` fallback (`prompt_n` / `predicted_n`) — PocketPal's
/// fix for under-reported local usage sourced exactly those fields.
/// Returns null when the result carries neither (older builds).
({int promptTokens, int completionTokens})? parseCompletionUsage(
    Map<dynamic, dynamic>? result) {
  if (result == null) return null;
  int? pick(String key) {
    final value = result[key];
    return value is num ? value.toInt() : null;
  }

  var prompt = pick('tokens_evaluated');
  var completion = pick('tokens_predicted');
  if (prompt == null || completion == null) {
    final timings = result['timings'];
    if (timings is Map) {
      prompt ??= (timings['prompt_n'] as num?)?.toInt();
      completion ??= (timings['predicted_n'] as num?)?.toInt();
    }
  }
  if (prompt == null && completion == null) return null;
  return (promptTokens: prompt ?? 0, completionTokens: completion ?? 0);
}

class LocalLlmEngine {
  double? _contextId;

  /// Usage reported by the most recent completion, when the binding
  /// surfaced it. Null when the build reports nothing — callers must
  /// fall back rather than fabricate.
  ({int promptTokens, int completionTokens})? lastCompletionUsage;

  Future<void> loadModel(String path) async {
    if (_contextId != null) return;
    final result = await Fllama.instance()?.initContext(path);
    if (result != null && result['contextId'] != null) {
      _contextId = (result['contextId'] as num).toDouble();
    }
  }

  /// Exact token count for [text] under the loaded model's own
  /// tokenizer (llama.cpp tokenize via the binding) — the same
  /// tokenizer inference uses, so this is ground truth, not an
  /// estimate. Null when no model is loaded or the call fails.
  Future<int?> countTokens(String text) async {
    final contextId = _contextId;
    if (contextId == null) return null;
    try {
      final result = await Fllama.instance()?.tokenize(contextId, text: text);
      final tokens = result?['tokens'];
      if (tokens is List) return tokens.length;
      return null;
    } catch (_) {
      return null;
    }
  }

  Stream<String> streamGenerate(String prompt) {
    final controller = StreamController<String>();

    if (_contextId == null) {
      controller.addError(Exception('Model not loaded'));
      controller.close();
      return controller.stream;
    }

    StreamSubscription? sub;
    sub = Fllama.instance()?.onTokenStream?.listen((event) {
      final ctxIdStr = event['contextId']?.toString();
      if (ctxIdStr == _contextId?.toString()) {
        final result = event['result'];
        if (result is Map) {
          final token = result['token'] as String?;
          if (token != null) controller.add(token);
        }
      }
    }, onDone: () {
      controller.close();
    });

    Fllama.instance()
        ?.completion(_contextId!, prompt: prompt, emitRealtimeCompletion: true)
        .then((result) {
      // The completion result is where the binding reports usage;
      // it used to be discarded here.
      lastCompletionUsage = parseCompletionUsage(result);
      controller.close();
      sub?.cancel();
    }).catchError((e) {
      controller.addError(e);
      controller.close();
      sub?.cancel();
    });

    return controller.stream;
  }
}
