import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lightweight summary of one indexed Knowledge Hub source, shared
/// across features through `core/` (AGENTS.md: features never import
/// another feature's `data/` or `view_models/` directly).
///
/// The Knowledge Hub view model owns the full source records and
/// syncs these summaries here whenever its source list changes —
/// the same pattern as `indexedReposProvider` /
/// `activeKevCountProvider` in `workspace_mode_provider.dart`.
class IndexedSourceSummary {
  final String id;
  final String name;
  final String subtitle;

  const IndexedSourceSummary({
    required this.id,
    required this.name,
    required this.subtitle,
  });
}

/// Indexed Knowledge Hub sources (GET /api/admin/sources), synced by
/// the Knowledge Hub view model.
final indexedKnowledgeSourcesProvider =
    StateProvider<List<IndexedSourceSummary>>((ref) => const []);

/// Whether the Knowledge Hub source list has been loaded at least
/// once this session (synced alongside [indexedKnowledgeSourcesProvider]).
final indexedKnowledgeSourcesLoadedProvider =
    StateProvider<bool>((ref) => false);

/// Load-request counter for the indexed source list. A feature that
/// needs the sources (e.g. the Code sources popover) increments this
/// instead of importing the Knowledge Hub view model; the view model
/// listens and refetches. If it has never been created, its
/// constructor fetch on first creation satisfies the request.
final indexedSourcesLoadRequestProvider = StateProvider<int>((ref) => 0);
