import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiKeyStorage {
  final _storage = const FlutterSecureStorage();

  String _getKeyName(String provider) {
    return '${provider.toLowerCase()}_api_key';
  }

  String _getExpiresName(String provider) {
    return '${provider.toLowerCase()}_api_key_expires';
  }

  Future<void> saveKey(String provider, String key, {String? expiresIn}) async {
    await _storage.write(key: _getKeyName(provider), value: key);

    if (expiresIn != null && expiresIn != 'never') {
      DateTime? expireDate;
      if (expiresIn == 'In 30 minutes') {
        expireDate = DateTime.now().add(const Duration(minutes: 30));
      } else if (expiresIn == 'In 2 hours') {
        expireDate = DateTime.now().add(const Duration(hours: 2));
      } else if (expiresIn == 'In 12 hours') {
        expireDate = DateTime.now().add(const Duration(hours: 12));
      } else if (expiresIn == 'In 1 day') {
        expireDate = DateTime.now().add(const Duration(days: 1));
      } else if (expiresIn == 'In 7 days') {
        expireDate = DateTime.now().add(const Duration(days: 7));
      } else if (expiresIn == 'In 30 days') {
        expireDate = DateTime.now().add(const Duration(days: 30));
      }
      if (expireDate != null) {
        await _storage.write(
            key: _getExpiresName(provider),
            value: expireDate.toIso8601String());
      } else {
        await _storage.delete(key: _getExpiresName(provider));
      }
    } else {
      await _storage.delete(key: _getExpiresName(provider));
    }
  }

  Future<String?> getKey(String provider) async {
    if (await isKeyExpired(provider)) return null;
    return await _storage.read(key: _getKeyName(provider));
  }

  Future<bool> isKeyExpired(String provider) async {
    final expireStr = await _storage.read(key: _getExpiresName(provider));
    if (expireStr == null) return false;
    final expireDate = DateTime.tryParse(expireStr);
    if (expireDate == null) return false;
    return DateTime.now().isAfter(expireDate);
  }

  Future<String?> getKeyExpirationDate(String provider) async {
    final expireStr = await _storage.read(key: _getExpiresName(provider));
    if (expireStr == null) return null;
    final expireDate = DateTime.tryParse(expireStr);
    if (expireDate == null) return null;
    // Format: 7/28/2026, 2:18:31 AM
    final month = expireDate.month;
    final day = expireDate.day;
    final year = expireDate.year;
    final hour = expireDate.hour % 12 == 0 ? 12 : expireDate.hour % 12;
    final min = expireDate.minute.toString().padLeft(2, '0');
    final sec = expireDate.second.toString().padLeft(2, '0');
    final ampm = expireDate.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/$year, $hour:$min:$sec $ampm';
  }

  Future<void> clearKey(String provider) async {
    await _storage.delete(key: _getKeyName(provider));
    await _storage.delete(key: _getExpiresName(provider));
  }

  Future<void> saveValue(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  Future<String?> getValue(String key) async {
    return await _storage.read(key: key);
  }

  // --- BYOD Database Getters & Setters ---
  
  Future<void> saveByodConfig({
    required String neo4jUri,
    required String neo4jUser,
    required String neo4jPass,
    required String qdrantUrl,
    required String qdrantKey,
  }) async {
    await saveValue('byod_neo4j_uri', neo4jUri);
    await saveValue('byod_neo4j_user', neo4jUser);
    await saveValue('byod_neo4j_pass', neo4jPass);
    await saveValue('byod_qdrant_url', qdrantUrl);
    await saveValue('byod_qdrant_key', qdrantKey);
  }

  Future<Map<String, String>> getByodConfig() async {
    return {
      'neo4j_uri': await getValue('byod_neo4j_uri') ?? '',
      'neo4j_user': await getValue('byod_neo4j_user') ?? '',
      'neo4j_pass': await getValue('byod_neo4j_pass') ?? '',
      'qdrant_url': await getValue('byod_qdrant_url') ?? '',
      'qdrant_key': await getValue('byod_qdrant_key') ?? '',
    };
  }
}
