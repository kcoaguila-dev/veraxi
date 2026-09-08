import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// State for model selection, persisted via SharedPreferences.
class ModelSelectionState {
  final String selectedModel;
  final String? selectedProvider;
  final Set<String> pinnedModels;

  const ModelSelectionState({
    this.selectedModel = 'Select a model',
    this.selectedProvider,
    this.pinnedModels = const {},
  });

  ModelSelectionState copyWith({
    String? selectedModel,
    String? selectedProvider,
    bool clearProvider = false,
    Set<String>? pinnedModels,
  }) {
    return ModelSelectionState(
      selectedModel: selectedModel ?? this.selectedModel,
      selectedProvider:
          clearProvider ? null : (selectedProvider ?? this.selectedProvider),
      pinnedModels: pinnedModels ?? this.pinnedModels,
    );
  }
}

final modelSelectionProvider =
    NotifierProvider<ModelSelectionViewModel, ModelSelectionState>(
  () => ModelSelectionViewModel(),
);

class ModelSelectionViewModel extends Notifier<ModelSelectionState> {
  @override
  ModelSelectionState build() {
    Future.microtask(() => _loadSaved());
    return const ModelSelectionState();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final savedModel = prefs.getString('selected_model');
    final savedProvider = prefs.getString('selected_provider');
    final savedPinned = prefs.getStringList('pinned_models');
    state = state.copyWith(
      selectedModel: savedModel ?? state.selectedModel,
      selectedProvider: savedProvider,
      pinnedModels: savedPinned?.toSet() ?? state.pinnedModels,
    );
  }

  Future<void> selectModel(String model, {String? provider}) async {
    state = state.copyWith(
      selectedModel: model,
      selectedProvider: provider,
      clearProvider: provider == null,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_model', model);
    if (provider != null) {
      await prefs.setString('selected_provider', provider);
    } else {
      await prefs.remove('selected_provider');
    }
  }

  Future<void> pinModel(String model) async {
    final updated = {...state.pinnedModels, model};
    state = state.copyWith(pinnedModels: updated);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('pinned_models', updated.toList());
  }

  Future<void> unpinModel(String model) async {
    final updated = {...state.pinnedModels}..remove(model);
    state = state.copyWith(pinnedModels: updated);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('pinned_models', updated.toList());
  }
}
