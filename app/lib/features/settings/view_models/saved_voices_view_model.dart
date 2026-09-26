import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/voices_repository.dart';

final voicesRepositoryProvider = Provider<VoicesRepository>((ref) {
  return VoicesRepository(Supabase.instance.client);
});

final savedVoicesProvider =
    StateNotifierProvider<SavedVoicesNotifier, AsyncValue<List<SavedVoice>>>(
        (ref) {
  final repository = ref.watch(voicesRepositoryProvider);
  return SavedVoicesNotifier(repository);
});

class SavedVoicesNotifier extends StateNotifier<AsyncValue<List<SavedVoice>>> {
  final VoicesRepository _repository;

  SavedVoicesNotifier(this._repository) : super(const AsyncValue.loading()) {
    loadVoices();
  }

  Future<void> loadVoices() async {
    state = const AsyncValue.loading();
    try {
      final voices = await _repository.getSavedVoices();
      state = AsyncValue.data(voices);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> saveVoice(String name, String referenceId) async {
    try {
      final newVoice = await _repository.saveVoice(name, referenceId);
      state = state.whenData((voices) => [newVoice, ...voices]);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> deleteVoice(String id) async {
    try {
      await _repository.deleteVoice(id);
      state =
          state.whenData((voices) => voices.where((v) => v.id != id).toList());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}
