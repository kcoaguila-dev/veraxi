import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/features/auth/data/auth_repository.dart';

final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges;
});

final authViewModelProvider = StateNotifierProvider<AuthViewModel, AsyncValue<User?>>((ref) {
  final repository = ref.watch(authRepositoryProvider);
  return AuthViewModel(repository);
});

class AuthViewModel extends StateNotifier<AsyncValue<User?>> {
  final AuthRepository _repository;

  AuthViewModel(this._repository) : super(const AsyncValue.loading()) {
    _init();
  }

  void _init() {
    state = AsyncValue.data(_repository.currentUser);
    _repository.authStateChanges.listen((data) {
      state = AsyncValue.data(data.session?.user);
    }, onError: (e, st) {
      state = AsyncValue.error(e, st);
    });
  }

  Future<void> signIn(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      await _repository.signInWithEmail(email, password);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> signUp(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      await _repository.signUpWithEmail(email, password);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> signOut() async {
    try {
      await _repository.signOut();
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}
