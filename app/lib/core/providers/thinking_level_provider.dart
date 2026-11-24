import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/models/model_thinking_capability.dart';
import 'package:veraxi_app/core/repositories/model_config_repository.dart';

/// Backend-sourced thinking capabilities, cached for the session.
/// Falls back cleanly to `ModelThinkingCapability.forModel(...)` offline.
final modelCapabilitiesProvider =
    FutureProvider<Map<String, ModelThinkingCapability>>((ref) async {
  final repo = ref.watch(modelConfigRepositoryProvider);
  return repo.getModelCapabilities();
});

/// Resolves the capability for [modelName], preferring backend-reported
/// capabilities (including live local runtime probes) and falling back
/// to local heuristics.
ModelThinkingCapability resolveModelCapability(
  String? modelName,
  Map<String, ModelThinkingCapability> capabilities,
) {
  if (modelName == null || modelName.isEmpty || modelName == 'Select a model') {
    return ModelThinkingCapability.none;
  }
  return capabilities[modelName] ??
      capabilities['local::$modelName'] ??
      ModelThinkingCapability.forModel(modelName);
}

/// Persists the user's chosen thinking level **per model** under
/// `thinking_level_by_model` in SharedPreferences.
final thinkingLevelByModelProvider =
    NotifierProvider<ThinkingLevelByModelNotifier, Map<String, String>>(
  () => ThinkingLevelByModelNotifier(),
);

class ThinkingLevelByModelNotifier extends Notifier<Map<String, String>> {
  static const String storageKey = 'thinking_level_by_model';
  bool _userChanged = false;

  @override
  Map<String, String> build() {
    _userChanged = false;
    Future.microtask(() => _loadSaved());
    return const {};
  }

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (_userChanged || raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = decoded.map(
          (k, v) => MapEntry(k.toString(), v.toString().toLowerCase()),
        );
      }
    } catch (_) {
      // Ignore SharedPreferences errors in tests/headless environments.
    }
  }

  Future<void> setLevelForModel(String modelName, String level) async {
    if (modelName.isEmpty || modelName == 'Select a model') return;
    _userChanged = true;
    final normalized = level.trim().toLowerCase();
    final updated = {...state, modelName: normalized};
    state = updated;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(updated));
    } catch (_) {
      // Ignore persistence errors in tests.
    }
  }
}

/// Returns the clamped effective thinking level for [modelName], or `null`
/// if [modelName] does not support reasoning/thinking.
String? resolveEffectiveThinkingLevel({
  required String? modelName,
  required Map<String, String> savedByModel,
  required Map<String, ModelThinkingCapability> capabilities,
  String? fallbackLevel,
}) {
  final cap = resolveModelCapability(modelName, capabilities);
  if (!cap.supportsReasoning) return null;
  final saved = modelName != null ? savedByModel[modelName] : null;
  return cap.clampLevel(saved ?? fallbackLevel);
}
