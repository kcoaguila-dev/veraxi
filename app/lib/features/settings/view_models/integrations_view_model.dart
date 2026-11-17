import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/features/settings/data/integrations_repository.dart';

// Re-export the models so views can import them from the ViewModel layer
// without violating the views → view_models → data dependency contract.
export 'package:veraxi_app/features/settings/data/integrations_repository.dart'
    show IntegrationModel, OAuthProviderModel;

/// State for the Integrations settings tab.
class IntegrationsState {
  final AsyncValue<List<IntegrationModel>> integrations;
  final AsyncValue<List<OAuthProviderModel>> providers;

  /// Transient result of the last Test Connection action, keyed by id.
  final Map<String, String> testResults;

  /// Transient status of the last repo-sync action, keyed by id.
  final Map<String, String> syncResults;

  const IntegrationsState({
    this.integrations = const AsyncValue.loading(),
    this.providers = const AsyncValue.loading(),
    this.testResults = const {},
    this.syncResults = const {},
  });

  IntegrationsState copyWith({
    AsyncValue<List<IntegrationModel>>? integrations,
    AsyncValue<List<OAuthProviderModel>>? providers,
    Map<String, String>? testResults,
    Map<String, String>? syncResults,
  }) {
    return IntegrationsState(
      integrations: integrations ?? this.integrations,
      providers: providers ?? this.providers,
      testResults: testResults ?? this.testResults,
      syncResults: syncResults ?? this.syncResults,
    );
  }
}

final integrationsViewModelProvider =
    StateNotifierProvider<IntegrationsViewModel, IntegrationsState>((ref) {
  final repository = ref.watch(integrationsRepositoryProvider);
  return IntegrationsViewModel(repository);
});

class IntegrationsViewModel extends StateNotifier<IntegrationsState> {
  final IntegrationsRepository _repository;

  IntegrationsViewModel(this._repository) : super(const IntegrationsState()) {
    load();
  }

  Future<void> load() async {
    state = state.copyWith(
      integrations: const AsyncValue.loading(),
      providers: const AsyncValue.loading(),
    );
    try {
      final integrations = await _repository.getIntegrations();
      state = state.copyWith(integrations: AsyncValue.data(integrations));
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(integrations: AsyncValue.error(e, st));
    }
    try {
      final providers = await _repository.getOAuthProviders();
      state = state.copyWith(providers: AsyncValue.data(providers));
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(providers: AsyncValue.error(e, st));
    }
  }

  Future<void> addMcpServer({
    required String displayName,
    required String url,
    String transport = 'auto',
    Map<String, String>? headers,
  }) async {
    try {
      await _repository.createMcpIntegration(
        displayName: displayName,
        url: url,
        transport: transport,
        headers: headers,
      );
      await load();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }

  Future<void> toggleIntegration(IntegrationModel integration, bool enabled) async {
    try {
      await _repository.patchIntegration(integration.id, isEnabled: enabled);
      await load();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }

  Future<void> removeIntegration(IntegrationModel integration) async {
    try {
      await _repository.deleteIntegration(integration.id);
      await load();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }

  Future<void> testIntegration(IntegrationModel integration) async {
    try {
      final result = await _repository.testIntegration(integration.id);
      final tools = (result['tools'] as List<dynamic>? ?? []).length;
      final latency = result['latency_ms'];
      state = state.copyWith(testResults: {
        ...state.testResults,
        integration.id: 'Connected · $tools tools · ${latency}ms',
      });
      await load();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(testResults: {
        ...state.testResults,
        integration.id: 'Connection failed',
      });
    }
  }

  /// Launch the provider OAuth flow in the browser.
  Future<void> connectOAuth(String provider) async {
    try {
      final url = await _repository.startOAuth(provider);
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not launch OAuth URL');
      }
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }

  Future<void> syncRepos(
    IntegrationModel integration, {
    required List<String> repos,
    bool includeIssues = false,
  }) async {
    try {
      final result = await _repository.syncIntegration(
        integration.id,
        repos: repos,
        includeIssues: includeIssues,
      );
      state = state.copyWith(syncResults: {
        ...state.syncResults,
        integration.id: 'Sync ${result['status'] ?? 'queued'}',
      });
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(syncResults: {
        ...state.syncResults,
        integration.id: 'Sync failed',
      });
    }
  }

  Future<Map<String, dynamic>> previewOpenApi({
    String? specText,
    String? specUrl,
  }) {
    return _repository.previewOpenApi(specText: specText, specUrl: specUrl);
  }

  Future<void> importOpenApi({
    String? displayName,
    String? specText,
    String? specUrl,
    required List<String> selectedOperationIds,
    String? serverUrl,
    String authType = 'bearer',
    String? authValue,
    String? authName,
  }) async {
    try {
      await _repository.createOpenApiIntegration(
        displayName: displayName,
        specText: specText,
        specUrl: specUrl,
        selectedOperationIds: selectedOperationIds,
        serverUrl: serverUrl,
        authType: authType,
        authValue: authValue,
        authName: authName,
      );
      await load();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }
}
