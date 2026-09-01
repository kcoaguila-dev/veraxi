import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/settings/data/api_keys_repository.dart';

/// State for the API Keys tab.
class ApiKeysState {
  final AsyncValue<List<ApiKeyModel>> keys;

  /// Holds the raw key string immediately after creation.
  /// Set to null once the user dismisses the reveal dialog.
  final String? newlyCreatedKey;

  const ApiKeysState({
    this.keys = const AsyncValue.loading(),
    this.newlyCreatedKey,
  });

  ApiKeysState copyWith({
    AsyncValue<List<ApiKeyModel>>? keys,
    String? newlyCreatedKey,
    bool clearNewKey = false,
  }) {
    return ApiKeysState(
      keys: keys ?? this.keys,
      newlyCreatedKey:
          clearNewKey ? null : (newlyCreatedKey ?? this.newlyCreatedKey),
    );
  }
}

final apiKeysViewModelProvider =
    StateNotifierProvider<ApiKeysViewModel, ApiKeysState>((ref) {
  final repository = ref.watch(apiKeysRepositoryProvider);
  return ApiKeysViewModel(repository);
});

class ApiKeysViewModel extends StateNotifier<ApiKeysState> {
  final ApiKeysRepository _repository;

  ApiKeysViewModel(this._repository) : super(const ApiKeysState()) {
    loadKeys();
  }

  /// Load (or reload) the list of API keys from the backend.
  Future<void> loadKeys() async {
    state = state.copyWith(keys: const AsyncValue.loading());
    try {
      final keys = await _repository.getApiKeys();
      state = state.copyWith(keys: AsyncValue.data(keys));
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(keys: AsyncValue.error(e, st));
    }
  }

  /// Generate a new API key. On success, [ApiKeysState.newlyCreatedKey] is
  /// populated with the raw key for one-time display.
  Future<void> createKey(String name) async {
    try {
      final result = await _repository.createApiKey(name);
      final rawKey = result['key'] as String;
      await loadKeys(); // Refresh the list
      // Surface the raw key for the reveal dialog
      state = state.copyWith(newlyCreatedKey: rawKey);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }

  /// Revoke an API key and remove it from the displayed list.
  Future<void> revokeKey(String keyId) async {
    try {
      await _repository.revokeApiKey(keyId);
      await loadKeys();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }

  /// Called after the user has dismissed the one-time reveal dialog.
  void clearNewlyCreatedKey() {
    state = state.copyWith(clearNewKey: true);
  }
}
