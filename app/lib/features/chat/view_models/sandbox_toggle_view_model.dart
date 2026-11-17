import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// State for the per-chat Sandbox toggle in the composer Tools menu.
class SandboxToggleState {
  final bool enabled;
  final bool loaded;

  const SandboxToggleState({this.enabled = false, this.loaded = false});

  SandboxToggleState copyWith({bool? enabled, bool? loaded}) {
    return SandboxToggleState(
      enabled: enabled ?? this.enabled,
      loaded: loaded ?? this.loaded,
    );
  }
}

final sandboxToggleViewModelProvider =
    StateNotifierProvider<SandboxToggleViewModel, SandboxToggleState>((ref) {
  return SandboxToggleViewModel();
});

/// Persists the Sandbox toggle into `tool_settings['sandbox_enabled']` —
/// the same SharedPreferences JSON document the chat send path reads and
/// forwards to the backend, which only injects the sandbox tools
/// (`sandbox_exec`, `sandbox_read_file`, `sandbox_write_file`,
/// `sandbox_diff`) for chats where it is true.
class SandboxToggleViewModel extends StateNotifier<SandboxToggleState> {
  SandboxToggleViewModel() : super(const SandboxToggleState()) {
    load();
  }

  /// Bumped by [setEnabled] so a slow in-flight [load] cannot overwrite
  /// a toggle the user just made.
  int _revision = 0;

  Future<void> load() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (revision != _revision) return;
      final settingsJson = prefs.getString('tool_settings');
      var enabled = false;
      if ((settingsJson ?? '').isNotEmpty) {
        try {
          final settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
          enabled = settings['sandbox_enabled'] as bool? ?? false;
        } catch (e, st) {
          await Sentry.captureException(e, stackTrace: st);
        }
      }
      if (revision != _revision) return;
      state = state.copyWith(enabled: enabled, loaded: true);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      if (revision != _revision) return;
      state = state.copyWith(loaded: true);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _revision++;
    state = state.copyWith(enabled: enabled, loaded: true);
    await _persist(enabled);
  }

  Future<void> toggle() => setEnabled(!state.enabled);

  Future<void> _persist(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settingsJson = prefs.getString('tool_settings');
      Map<String, dynamic> settings = {};
      if ((settingsJson ?? '').isNotEmpty) {
        try {
          settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
        } catch (_) {}
      }
      settings['sandbox_enabled'] = enabled;
      await prefs.setString('tool_settings', jsonEncode(settings));
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
    }
  }
}
