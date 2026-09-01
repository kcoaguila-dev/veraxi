import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

final ttsRepositoryProvider = Provider<TTSRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return TTSRepository(apiClient: apiClient);
});

class TTSRepository {
  final ApiClient apiClient;

  TTSRepository({required this.apiClient});

  Future<List<Map<String, dynamic>>> getVoices({String? gptSovitsUrl}) async {
    String path = '/voices';
    if (gptSovitsUrl != null && gptSovitsUrl.isNotEmpty) {
      path += '?gpt_sovits_url=${Uri.encodeQueryComponent(gptSovitsUrl)}';
    }
    final data = await apiClient.get(path);
    final List<dynamic> rawVoices = data['voices'] ?? [];
    return rawVoices.map((v) => Map<String, dynamic>.from(v)).toList();
  }

  Future<void> saveVoices(List<Map<String, dynamic>> voices) async {
    await apiClient.post('/voices', body: {'voices': voices});
  }

  Future<void> uploadVoice(String name, String promptText, List<int> fileBytes,
      String fileName) async {
    final uri = Uri.parse('${apiClient.baseUrl}/voices/upload');
    final request = http.MultipartRequest('POST', uri);

    final headers = await apiClient.getDefaultHeaders();
    request.headers.addAll(headers);

    request.fields['name'] = name;
    request.fields['prompt_text'] = promptText;

    final multipartFile = http.MultipartFile.fromBytes(
      'file',
      fileBytes,
      filename: fileName,
    );
    request.files.add(multipartFile);

    final streamedResponse = await apiClient.client.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to upload voice: ${response.statusCode} - ${response.body}');
    }
  }

  Future<List<int>> getAudioBytes(String text, String voiceId,
      {String? gptSovitsUrl}) async {
    final uri = Uri.parse('${apiClient.baseUrl}/chat/audio');
    final headers = await apiClient.getDefaultHeaders();
    headers['Content-Type'] = 'application/json';
    if (gptSovitsUrl != null) {
      headers['X-GPT-SoVITS-Url'] = gptSovitsUrl;
    }
    final body = jsonEncode({'text': text, 'voice_id': voiceId});

    final response =
        await apiClient.client.post(uri, headers: headers, body: body);

    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw Exception('Backend synthesis failed: ${response.statusCode}');
    }
  }
}
