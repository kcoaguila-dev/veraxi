import 'dart:convert';
import 'dart:math' as math;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/network/api_client.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    apiClient: ref.watch(apiClientProvider),
    storage: ref.watch(apiKeyStorageProvider),
  );
});

class SyncService {
  final ApiClient apiClient;
  final ApiKeyStorage storage;

  SyncService({required this.apiClient, required this.storage});

  Future<void> pushSync(String passphrase) async {
    final data = await storage.exportAll();
    final jsonStr = jsonEncode(data);

    // 1. Generate salt
    final salt = _generateSalt();

    // 2. Derive key
    final secretKey = await _deriveKey(passphrase, salt);

    // 3. Encrypt
    final algorithm = AesGcm.with256bits();
    final secretBox = await algorithm.encrypt(
      utf8.encode(jsonStr),
      secretKey: secretKey,
    );

    // 4. Encode
    final encryptedBlob = base64Encode(secretBox.concatenation());
    final saltStr = base64Encode(salt);

    // 5. Upload
    await apiClient.put('/sync/byod', body: {
      'encrypted_blob': encryptedBlob,
      'salt': saltStr,
    });
  }

  Future<void> pullSync(String passphrase) async {
    // 1. Download
    final response = await apiClient.get('/sync/byod');
    final encryptedBlob = response['encrypted_blob'] as String;
    final saltStr = response['salt'] as String;

    final concatenation = base64Decode(encryptedBlob);
    final salt = base64Decode(saltStr);

    final secretBox = SecretBox.fromConcatenation(
      concatenation,
      nonceLength: 12,
      macLength: 16,
    );

    // 2. Derive key
    final secretKey = await _deriveKey(passphrase, salt);

    // 3. Decrypt
    final algorithm = AesGcm.with256bits();
    final clearTextBytes = await algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    // 4. Import
    final jsonStr = utf8.decode(clearTextBytes);
    final data = Map<String, String>.from(jsonDecode(jsonStr));
    await storage.importAll(data);
  }

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    return await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  List<int> _generateSalt() {
    final bytes = <int>[];
    final random = math.Random.secure();
    for (var i = 0; i < 16; i++) {
      bytes.add(random.nextInt(256));
    }
    return bytes;
  }
}
