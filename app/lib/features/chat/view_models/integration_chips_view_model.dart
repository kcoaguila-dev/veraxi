import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

/// One attachable integration shown as a chip above the chat input.
class IntegrationChipItem {
  final String id;
  final String displayName;
  final bool isEnabled;

  const IntegrationChipItem({
    required this.id,
    required this.displayName,
    required this.isEnabled,
  });

  factory IntegrationChipItem.fromJson(Map<String, dynamic> json) {
    return IntegrationChipItem(
      id: json['id'] as String,
      displayName: json['display_name'] as String? ?? '',
      isEnabled: json['is_enabled'] as bool? ?? true,
    );
  }
}

/// State for the chat-input integration chips.
///
/// [selectedIds] is null while the user has never toggled a chip for
/// this thread: the backend then attaches every enabled integration.
/// Once toggled, the selection is persisted into
/// `tool_settings['enabled_integration_ids']` (the same SharedPreferences
/// document the chat send path reads) and the backend filters to it.
class IntegrationChipsState {
  final List<IntegrationChipItem> integrations;
  final Set<String>? selectedIds;
  final bool loaded;

  const IntegrationChipsState({
    this.integrations = const [],
    this.selectedIds,
    this.loaded = false,
  });

  bool isSelected(IntegrationChipItem item) =>
      selectedIds == null || selectedIds!.contains(item.id);

  IntegrationChipsState copyWith({
    List<IntegrationChipItem>? integrations,
    Set<String>? selectedIds,
    bool? loaded,
  }) {
    return IntegrationChipsState(
      integrations: integrations ?? this.integrations,
      selectedIds: selectedIds ?? this.selectedIds,
      loaded: loaded ?? this.loaded,
    );
  }
}

final integrationChipsViewModelProvider =
    StateNotifierProvider<IntegrationChipsViewModel, IntegrationChipsState>(
        (ref) {
  final repository = ref.watch(chatRepositoryProvider);
  return IntegrationChipsViewModel(repository);
});

class IntegrationChipsViewModel extends StateNotifier<IntegrationChipsState> {
  final IChatRepository _repository;

  IntegrationChipsViewModel(this._repository)
      : super(const IntegrationChipsState()) {
    load();
  }

  Future<void> load() async {
    try {
      final raw = await _repository.getIntegrations();
      final items = raw
          .map(IntegrationChipItem.fromJson)
          .where((item) => item.isEnabled)
          .toList();
      Set<String>? selected;
      final prefs = await SharedPreferences.getInstance();
      final settingsJson = prefs.getString('tool_settings');
      if ((settingsJson ?? '').isNotEmpty) {
        try {
          final settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
          final ids = settings['enabled_integration_ids'];
          if (ids is List) {
            selected = ids.map((e) => e.toString()).toSet();
          }
        } catch (e, st) {
          await Sentry.captureException(e, stackTrace: st);
        }
      }
      state = state.copyWith(
        integrations: items,
        selectedIds: selected,
        loaded: true,
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(loaded: true);
    }
  }

  Future<void> toggle(IntegrationChipItem item) async {
    final current = state.selectedIds ??
        state.integrations.map((i) => i.id).toSet();
    final next = Set<String>.from(current);
    if (next.contains(item.id)) {
      next.remove(item.id);
    } else {
      next.add(item.id);
    }
    state = state.copyWith(selectedIds: next);
    await _persist(next);
  }

  Future<void> _persist(Set<String> selectedIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settingsJson = prefs.getString('tool_settings');
      Map<String, dynamic> settings = {};
      if ((settingsJson ?? '').isNotEmpty) {
        try {
          settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
        } catch (_) {}
      }
      settings['enabled_integration_ids'] = selectedIds.toList();
      await prefs.setString('tool_settings', jsonEncode(settings));
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
    }
  }
}
