import 'dart:async';
import 'package:fllama/fllama.dart';

class LocalLlmEngine {
  double? _contextId;

  Future<void> loadModel(String path) async {
    if (_contextId != null) return;
    final result = await Fllama.instance()?.initContext(path);
    if (result != null && result['contextId'] != null) {
      _contextId = (result['contextId'] as num).toDouble();
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
      if (event['contextId'] == _contextId) {
        final token = event['token'] as String?;
        if (token != null) controller.add(token);
      }
    }, onDone: () {
      controller.close();
    });

    Fllama.instance()?.completion(_contextId!, prompt: prompt, emitRealtimeCompletion: true).then((_) {
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
