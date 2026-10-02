import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ModelDownloadState {
  final bool isDownloading;
  final String modelTag;
  final double progress;
  final String status;

  const ModelDownloadState({
    this.isDownloading = false,
    this.modelTag = '',
    this.progress = 0.0,
    this.status = '',
  });

  ModelDownloadState copyWith({
    bool? isDownloading,
    String? modelTag,
    double? progress,
    String? status,
  }) {
    return ModelDownloadState(
      isDownloading: isDownloading ?? this.isDownloading,
      modelTag: modelTag ?? this.modelTag,
      progress: progress ?? this.progress,
      status: status ?? this.status,
    );
  }
}

class ModelDownloadNotifier extends StateNotifier<ModelDownloadState> {
  /// [client] can be injected for testing; defaults to a real [http.Client].
  final http.Client _client;

  ModelDownloadNotifier({http.Client? client})
      : _client = client ?? http.Client(),
        super(const ModelDownloadState());

  Future<void> pullOllamaModel(String modelName, String baseUrl) async {
    if (modelName.isEmpty || state.isDownloading) return;
    if (baseUrl.isEmpty || !baseUrl.startsWith('http')) return;

    String pullUrl = baseUrl;
    if (baseUrl.endsWith('/v1')) {
      pullUrl = baseUrl.replaceAll('/v1', '/api/pull');
    } else if (baseUrl.endsWith('/v1/')) {
      pullUrl = baseUrl.replaceAll('/v1/', '/api/pull');
    } else {
      pullUrl = '$baseUrl/api/pull';
    }

    state = state.copyWith(
      isDownloading: true,
      modelTag: modelName,
      progress: 0.0,
      status: 'Starting download for $modelName...',
    );

    try {
      final request = http.Request('POST', Uri.parse(pullUrl));
      request.body = jsonEncode({"name": modelName});
      request.headers['Content-Type'] = 'application/json';

      final response = await _client.send(request);

      if (response.statusCode == 200) {
        await for (final String chunk in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          try {
            final data = jsonDecode(chunk);
            if (data['status'] != null) {
              final status = data['status'].toString();
              if (data['total'] != null && data['completed'] != null) {
                final total = data['total'] as int;
                final completed = data['completed'] as int;
                if (total > 0) {
                  state = state.copyWith(
                    status: status,
                    progress: completed / total,
                  );
                } else {
                  state = state.copyWith(status: status);
                }
              } else {
                state = state.copyWith(status: status);
              }
            }
          } catch (_) {}
        }

        state = state.copyWith(
          status: 'Completed!',
          progress: 1.0,
        );
      } else {
        state = state.copyWith(
          status: 'Error: ${response.statusCode}',
        );
      }
    } catch (e) {
      state = state.copyWith(
        status: 'Error: Failed to connect',
      );
    } finally {
      // Keep completed status briefly before resetting
      await Future.delayed(const Duration(seconds: 3));
      state = const ModelDownloadState();
    }
  }

  Future<void> downloadLocalModel(String url, String fileName) async {
    if (url.isEmpty || state.isDownloading) return;

    state = state.copyWith(
      isDownloading: true,
      modelTag: fileName,
      progress: 0.0,
      status: 'Downloading $fileName...',
    );

    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await _client.send(request);

      if (response.statusCode == 200) {
        final totalBytes = response.contentLength ?? 0;
        int receivedBytes = 0;

        final appDocsDir = await getApplicationDocumentsDirectory();
        final file = File(p.join(appDocsDir.path, fileName));
        final sink = file.openWrite();

        await for (final chunk in response.stream) {
          receivedBytes += chunk.length;
          sink.add(chunk);
          if (totalBytes > 0) {
            state = state.copyWith(
              progress: receivedBytes / totalBytes,
              status:
                  'Downloading: ${(receivedBytes / 1024 / 1024).toStringAsFixed(1)} MB',
            );
          }
        }

        await sink.close();

        state = state.copyWith(
          status: 'Completed!',
          progress: 1.0,
        );
      } else {
        state = state.copyWith(status: 'Error: ${response.statusCode}');
      }
    } catch (e) {
      state = state.copyWith(status: 'Error: Failed to connect');
    } finally {
      await Future.delayed(const Duration(seconds: 3));
      state = const ModelDownloadState();
    }
  }
}

final modelDownloadProvider =
    StateNotifierProvider<ModelDownloadNotifier, ModelDownloadState>((ref) {
  return ModelDownloadNotifier();
});

/// Scans the app documents directory for downloaded .gguf model files.
/// Invalidated automatically whenever [modelDownloadProvider] completes a download.
final localGgufModelsProvider = FutureProvider<List<String>>((ref) async {
  // Re-scan whenever a download completes (state resets to idle).
  ref.watch(modelDownloadProvider.select((s) => s.isDownloading));

  final dir = await getApplicationDocumentsDirectory();
  final entities = dir.listSync();
  return entities
      .whereType<File>()
      .where((f) => f.path.endsWith('.gguf'))
      .map((f) => f.uri.pathSegments.last)
      .toList()
    ..sort();
});
