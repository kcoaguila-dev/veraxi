import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiKeyStorage {
  static const String _geminiKey = 'gemini_api_key';
  final _storage = const FlutterSecureStorage();

  Future<void> saveGeminiKey(String key) async {
    await _storage.write(key: _geminiKey, value: key);
  }

  Future<String?> getGeminiKey() async {
    return await _storage.read(key: _geminiKey);
  }

  Future<void> clearGeminiKey() async {
    await _storage.delete(key: _geminiKey);
  }
}
