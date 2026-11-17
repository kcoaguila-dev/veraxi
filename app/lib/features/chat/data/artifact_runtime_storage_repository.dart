import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';

/// Scoped persistent key-value storage for artifacts
/// (`window.veraxiStorage`): each artifact scope — a draft
/// (`{threadId}:{messageIndex}:{artifactIndex}`) or a published
/// artifact (`pub:{artifactId}`) — owns up to [maxKeysPerScope]
/// string entries. Local persistence is a dedicated Drift table
/// (structured data does not belong in a settings blob); the
/// backend copy syncs through `/api/artifacts/storage/...` under
/// the same limits, so the caps below mirror routes/artifacts.py.
const int maxStorageKeysPerScope = 100;
const int maxStorageValueChars = 100000;
const int maxStorageScopeChars = 2000000;

/// Thrown when a storage write would exceed a scope limit.
class ArtifactStorageLimitException implements Exception {
  final String message;
  const ArtifactStorageLimitException(this.message);
  @override
  String toString() => message;
}

/// The local persistence seam for runtime storage entries, so the
/// repository can be unit-tested without a database.
abstract class ArtifactRuntimeLocalStore {
  Future<Map<String, String>> entriesForScope(String scopeId);
  Future<void> put(String scopeId, String key, String value);
  Future<void> remove(String scopeId, String key);
}

/// Drift-backed local store: one row per (scope, key) in the chat
/// database's runtime-storage table.
class DriftArtifactRuntimeLocalStore implements ArtifactRuntimeLocalStore {
  DriftArtifactRuntimeLocalStore({LocalChatDatabase? database})
      : _db = database ?? LocalChatDatabase();

  final LocalChatDatabase _db;

  @override
  Future<Map<String, String>> entriesForScope(String scopeId) async {
    final rows = await (_db.select(_db.artifactRuntimeStorageEntries)
          ..where((t) => t.scopeId.equals(scopeId)))
        .get();
    return {for (final row in rows) row.entryKey: row.entryValue};
  }

  @override
  Future<void> put(String scopeId, String key, String value) async {
    await _db.into(_db.artifactRuntimeStorageEntries).insertOnConflictUpdate(
          ArtifactRuntimeStorageEntriesCompanion.insert(
            scopeId: scopeId,
            entryKey: key,
            entryValue: value,
            updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  @override
  Future<void> remove(String scopeId, String key) async {
    await (_db.delete(_db.artifactRuntimeStorageEntries)
          ..where((t) => t.scopeId.equals(scopeId) & t.entryKey.equals(key)))
        .go();
  }
}

/// In-memory local store for tests and ephemeral contexts.
class InMemoryArtifactRuntimeLocalStore
    implements ArtifactRuntimeLocalStore {
  final Map<String, Map<String, String>> scopes = {};

  @override
  Future<Map<String, String>> entriesForScope(String scopeId) async =>
      Map.of(scopes[scopeId] ?? const {});

  @override
  Future<void> put(String scopeId, String key, String value) async {
    (scopes[scopeId] ??= {})[key] = value;
  }

  @override
  Future<void> remove(String scopeId, String key) async {
    scopes[scopeId]?.remove(key);
  }
}

/// Runtime storage repository: validates limits, serves reads and
/// writes from the local store, and syncs with the backend in the
/// background / on scope load. Sync failures never break the
/// artifact — the local copy remains the fallback.
class ArtifactRuntimeStorageRepository {
  ArtifactRuntimeStorageRepository({
    required ArtifactRuntimeLocalStore local,
    ApiClient? apiClient,
  })  : _local = local,
        _apiClient = apiClient;

  final ArtifactRuntimeLocalStore _local;
  final ApiClient? _apiClient;
  final Set<String> _syncedScopes = {};

  void _validateKey(String key) {
    if (key.isEmpty || key.length > 500) {
      throw const ArtifactStorageLimitException(
        'key must be between 1 and 500 characters',
      );
    }
  }

  void _validateValue(String value) {
    if (value.length > maxStorageValueChars) {
      throw ArtifactStorageLimitException(
        'value too large (max $maxStorageValueChars characters)',
      );
    }
  }

  Future<String?> get(String scopeId, String key) async {
    _validateKey(key);
    await _ensureSynced(scopeId);
    final entries = await _local.entriesForScope(scopeId);
    return entries[key];
  }

  Future<void> set(String scopeId, String key, String value) async {
    _validateKey(key);
    _validateValue(value);
    final entries = await _local.entriesForScope(scopeId);
    if (!entries.containsKey(key) &&
        entries.length >= maxStorageKeysPerScope) {
      throw const ArtifactStorageLimitException(
        'too many keys for this artifact '
        '(max $maxStorageKeysPerScope)',
      );
    }
    final total = entries.entries
            .where((e) => e.key != key)
            .fold<int>(0, (sum, e) => sum + e.value.length) +
        value.length;
    if (total > maxStorageScopeChars) {
      throw const ArtifactStorageLimitException(
        'storage scope too large (max $maxStorageScopeChars characters)',
      );
    }
    await _local.put(scopeId, key, value);
    _syncSet(scopeId, key, value);
  }

  Future<void> delete(String scopeId, String key) async {
    _validateKey(key);
    await _local.remove(scopeId, key);
    final api = _apiClient;
    if (api == null) return;
    try {
      await api.delete(
        '/artifacts/storage/$scopeId/${Uri.encodeComponent(key)}',
      );
    } catch (e) {
      await Sentry.captureException(e);
    }
  }

  Future<List<String>> list(String scopeId, {String prefix = ''}) async {
    await _ensureSynced(scopeId);
    final entries = await _local.entriesForScope(scopeId);
    final keys = entries.keys.where((k) => k.startsWith(prefix)).toList()
      ..sort();
    return keys;
  }

  Future<void> _ensureSynced(String scopeId) async {
    final api = _apiClient;
    if (api == null || _syncedScopes.contains(scopeId)) return;
    _syncedScopes.add(scopeId);
    try {
      final data = await api.get('/artifacts/storage/$scopeId');
      final entries =
          (data as Map<String, dynamic>)['entries'] as Map<String, dynamic>? ??
              const {};
      for (final entry in entries.entries) {
        if (entry.value is String) {
          await _local.put(scopeId, entry.key, entry.value as String);
        }
      }
    } catch (e) {
      await Sentry.captureException(e);
    }
  }

  void _syncSet(String scopeId, String key, String value) {
    final api = _apiClient;
    if (api == null) return;
    () async {
      try {
        await api.put(
          '/artifacts/storage/$scopeId',
          body: {'key': key, 'value': value},
        );
      } catch (e) {
        await Sentry.captureException(e);
      }
    }();
  }
}

final artifactRuntimeStorageRepositoryProvider =
    Provider<ArtifactRuntimeStorageRepository>((ref) {
  return ArtifactRuntimeStorageRepository(
    local: DriftArtifactRuntimeLocalStore(),
    apiClient: ref.watch(apiClientProvider),
  );
});
