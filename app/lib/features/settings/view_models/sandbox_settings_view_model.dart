import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/settings/data/sandbox_repository.dart';

// Re-export the models so views can import them from the ViewModel layer
// without violating the views → view_models → data dependency contract.
export 'package:veraxi_app/features/settings/data/sandbox_repository.dart'
    show SandboxConfig, SandboxSessionInfo, SandboxTestResult;

/// State for the Code Sandboxes settings tab.
class SandboxSettingsState {
  final SandboxConfig? config;
  final List<SandboxSessionInfo> sessions;
  final bool loading;
  final bool saving;
  final bool testing;
  final SandboxTestResult? testResult;
  final String? error;
  final String? saveMessage;

  const SandboxSettingsState({
    this.config,
    this.sessions = const [],
    this.loading = true,
    this.saving = false,
    this.testing = false,
    this.testResult,
    this.error,
    this.saveMessage,
  });

  SandboxSettingsState copyWith({
    SandboxConfig? config,
    List<SandboxSessionInfo>? sessions,
    bool? loading,
    bool? saving,
    bool? testing,
    SandboxTestResult? testResult,
    String? error,
    String? saveMessage,
    bool clearTestResult = false,
    bool clearError = false,
    bool clearSaveMessage = false,
  }) {
    return SandboxSettingsState(
      config: config ?? this.config,
      sessions: sessions ?? this.sessions,
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      testing: testing ?? this.testing,
      testResult: clearTestResult ? null : (testResult ?? this.testResult),
      error: clearError ? null : (error ?? this.error),
      saveMessage: clearSaveMessage ? null : (saveMessage ?? this.saveMessage),
    );
  }
}

final sandboxSettingsViewModelProvider =
    StateNotifierProvider<SandboxSettingsViewModel, SandboxSettingsState>(
        (ref) {
  final repository = ref.watch(sandboxRepositoryProvider);
  return SandboxSettingsViewModel(repository);
});

class SandboxSettingsViewModel extends StateNotifier<SandboxSettingsState> {
  final SandboxRepository _repository;

  SandboxSettingsViewModel(this._repository)
      : super(const SandboxSettingsState()) {
    load();
  }

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final config = await _repository.getConfig();
      state = state.copyWith(config: config);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        config: state.config ?? const SandboxConfig(),
        error: 'Failed to load sandbox configuration',
      );
    }
    try {
      final sessions = await _repository.getSessions();
      state = state.copyWith(sessions: sessions, loading: false);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(loading: false);
    }
  }

  void _update(SandboxConfig Function(SandboxConfig current) change) {
    final current = state.config;
    if (current == null) return;
    state = state.copyWith(
      config: change(current),
      clearTestResult: true,
      clearSaveMessage: true,
    );
  }

  void setProvider(String provider) =>
      _update((c) => c.copyWith(provider: provider));

  void setDisplayName(String name) =>
      _update((c) => c.copyWith(displayName: name));

  void setBaseImage(String image) =>
      _update((c) => c.copyWith(baseImage: image));

  void setCpuCores(int cores) => _update((c) => c.copyWith(cpuCores: cores));

  void setMemoryMb(int memoryMb) =>
      _update((c) => c.copyWith(memoryMb: memoryMb));

  void setDiskGb(int diskGb) => _update((c) => c.copyWith(diskGb: diskGb));

  void setIdleTimeoutSec(int seconds) =>
      _update((c) => c.copyWith(idleTimeoutSec: seconds));

  void setAutonomyMode(String mode) =>
      _update((c) => c.copyWith(autonomyMode: mode));

  void setEgressMode(String mode) =>
      _update((c) => c.copyWith(egressMode: mode));

  void setIsolateGitBranch(bool value) =>
      _update((c) => c.copyWith(isolateGitBranch: value));

  void setRemoteUrl(String url) => _update((c) {
        final config = Map<String, dynamic>.from(c.config);
        if (url.trim().isEmpty) {
          config.remove('url');
        } else {
          config['url'] = url.trim();
        }
        return c.copyWith(config: config);
      });

  void addDomain(String domain) {
    final cleaned = domain.trim().toLowerCase();
    if (cleaned.isEmpty) return;
    _update((c) {
      if (c.allowedDomains.contains(cleaned)) return c;
      return c.copyWith(allowedDomains: [...c.allowedDomains, cleaned]);
    });
  }

  void removeDomain(String domain) => _update((c) => c.copyWith(
      allowedDomains: c.allowedDomains.where((d) => d != domain).toList()));

  /// Persists the current config. [secrets] entries that are empty are
  /// dropped so a blank field never wipes a stored secret.
  Future<void> save({Map<String, String> secrets = const {}}) async {
    final config = state.config;
    if (config == null) return;
    state = state.copyWith(saving: true, clearError: true);
    try {
      final nonEmpty = Map<String, String>.fromEntries(
        secrets.entries.where((e) => e.value.isNotEmpty),
      );
      final saved = await _repository.saveConfig(
        config,
        secrets: nonEmpty.isEmpty ? null : nonEmpty,
      );
      state = state.copyWith(
        config: saved,
        saving: false,
        saveMessage: 'Sandbox configuration saved',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        saving: false,
        error: 'Failed to save sandbox configuration',
      );
    }
  }

  Future<void> testSandbox() async {
    state = state.copyWith(testing: true, clearTestResult: true);
    try {
      final result = await _repository.testSandbox();
      state = state.copyWith(testing: false, testResult: result);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        testing: false,
        testResult: SandboxTestResult(
          ok: false,
          error: 'Sandbox test failed: $e',
        ),
      );
    }
  }

  Future<void> pauseSession(SandboxSessionInfo session) async {
    try {
      await _repository.pauseSession(session.id);
      await load();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to pause sandbox session');
    }
  }

  Future<void> destroySession(SandboxSessionInfo session) async {
    try {
      await _repository.destroySession(session.id);
      await load();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to destroy sandbox session');
    }
  }
}
