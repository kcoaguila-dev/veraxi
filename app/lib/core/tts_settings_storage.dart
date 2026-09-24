import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TTSSettingsStorage {
  static const String _voiceIdKey = 'tts_voice_id';
  static const String _fishAudioApiKeyKey = 'tts_fish_audio_api_key';
  static const String _fishAudioModelKey = 'tts_fish_audio_model';
  static const String _fishAudioRefIdKey = 'tts_fish_audio_ref_id';
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

  Future<void> saveFishAudioApiKey(String apiKey) async {
    await _storage.write(key: _fishAudioApiKeyKey, value: apiKey);
  }

  Future<String?> getFishAudioApiKey() async {
    return await _storage.read(key: _fishAudioApiKeyKey);
  }

  Future<void> saveFishAudioModel(String model) async {
    await _storage.write(key: _fishAudioModelKey, value: model);
  }

  Future<String?> getFishAudioModel() async {
    return await _storage.read(key: _fishAudioModelKey);
  }

  Future<void> saveFishAudioReferenceId(String refId) async {
    await _storage.write(key: _fishAudioRefIdKey, value: refId);
  }

  Future<String?> getFishAudioReferenceId() async {
    return await _storage.read(key: _fishAudioRefIdKey);
  }
}
