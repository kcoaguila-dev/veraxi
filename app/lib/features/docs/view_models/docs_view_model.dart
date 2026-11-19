import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/docs/data/docs_catalog.dart';

export 'package:veraxi_app/features/docs/data/docs_catalog.dart';

class DocsState {
  final String selectedId;
  final String filterQuery;

  const DocsState({
    this.selectedId = 'quickstart',
    this.filterQuery = '',
  });

  List<DocEntry> get filteredEntries =>
      kDocsCatalog.where((entry) => entry.matches(filterQuery)).toList();

  DocEntry get selectedEntry {
    return kDocsCatalog.firstWhere(
      (entry) => entry.id == selectedId,
      orElse: () => kDocsCatalog.first,
    );
  }

  DocsState copyWith({String? selectedId, String? filterQuery}) {
    return DocsState(
      selectedId: selectedId ?? this.selectedId,
      filterQuery: filterQuery ?? this.filterQuery,
    );
  }
}

class DocsViewModel extends StateNotifier<DocsState> {
  DocsViewModel() : super(const DocsState());

  void selectEntry(String id) {
    state = state.copyWith(selectedId: id);
  }

  void setFilter(String query) {
    state = state.copyWith(filterQuery: query);
  }

  void clearFilter() {
    state = state.copyWith(filterQuery: '');
  }
}

final docsViewModelProvider =
    StateNotifierProvider<DocsViewModel, DocsState>((ref) {
  return DocsViewModel();
});
