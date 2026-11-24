import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

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

/// Ensures [indexedKnowledgeSourcesProvider] is populated on cold start
/// even when the Knowledge Hub screen has not been visited yet.
Future<void> ensureIndexedKnowledgeSourcesLoaded(WidgetRef ref) async {
  if (ref.read(indexedKnowledgeSourcesLoadedProvider)) return;
  ref.read(indexedSourcesLoadRequestProvider.notifier).state++;
  try {
    final client = ref.read(apiClientProvider);
    final data = await client.get('/admin/sources');
    final raw = (data is Map ? data['sources'] : data) as List? ?? const [];
    final summaries = <IndexedSourceSummary>[];
    for (final item in raw.whereType<Map>()) {
      final id = (item['id'] ?? item['source'] ?? '').toString();
      if (id.isEmpty) continue;
      final name = (item['name'] ?? item['title'] ?? id).toString();
      final count = item['chunk_count'] ?? item['chunks'];
      final subtitle = count != null ? '$count chunks' : '';
      summaries
          .add(IndexedSourceSummary(id: id, name: name, subtitle: subtitle));
    }
    ref.read(indexedKnowledgeSourcesProvider.notifier).state = summaries;
    ref.read(indexedKnowledgeSourcesLoadedProvider.notifier).state = true;
  } catch (_) {
    // Fail-soft: KnowledgeHubViewModel will still populate when visited.
  }
}
