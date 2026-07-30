import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TTSSettingsStorage {
  static const String _voiceIdKey = 'tts_voice_id';
  final _storage = const FlutterSecureStorage();

  Future<void> saveVoiceId(String voiceId) async {
    await _storage.write(key: _voiceIdKey, value: voiceId);
  }

  Future<String?> getVoiceId() async {
    return await _storage.read(key: _voiceIdKey);
  }

  Future<void> clearVoiceId() async {
    await _storage.delete(key: _voiceIdKey);
  }

  Future<void> saveEngine(String engine) async {
    await _storage.write(key: 'tts_engine', value: engine);
  }

  Future<String?> getEngine() async {
    return await _storage.read(key: 'tts_engine');
  }

  Future<void> saveGptSovitsUrl(String url) async {
    await _storage.write(key: 'tts_gpt_sovits_url', value: url);
  }

  Future<String?> getGptSovitsUrl() async {
    return await _storage.read(key: 'tts_gpt_sovits_url');
  }
}
