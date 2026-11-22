import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/knowledge_hub/data/knowledge_hub_repository.dart';

class MockApiClient extends Mock implements ApiClient {}

void main() {
  late MockApiClient mockApiClient;
  late KnowledgeHubRepository repository;

  setUp(() {
    mockApiClient = MockApiClient();
    repository = KnowledgeHubRepository(apiClient: mockApiClient);
  });

  test('fetchStats parses both camelCase and snake_case backend payloads',
      () async {
    when(() => mockApiClient.get('/admin/stats')).thenAnswer((_) async => {
          'node_count': 3210,
          'vector_count': 1840,
          'source_count': 142,
        });
    final res = await repository.fetchStats();
    expect(res.nodeCount, 3210);
    expect(res.vectorCount, 1840);
    expect(res.sourceCount, 142);
    verify(() => mockApiClient.get('/admin/stats')).called(1);
  });

  test('fetchSources, reindexSource, and deleteSource call admin endpoints',
      () async {
    when(() => mockApiClient.get('/admin/sources')).thenAnswer((_) async => {
          'sources': [
            {
              'id': 'guide.pdf',
              'name': 'guide.pdf',
              'subtitle': 'Ingested Document',
              'type': 'PDF',
              'category': 'doc',
              'counts': '12 chunks · 24 nodes',
              'last_synced': '18d ago',
              'is_stale': true,
            }
          ],
          'queue': [
            {
              'job_id': 'job-1',
              'source': 'arch_v3.pdf',
              'stage': 'Chunking + Dual-Write',
              'progress': 0.78,
            }
          ],
        });
    when(() => mockApiClient.post('/admin/sources/reindex',
            body: any(named: 'body')))
        .thenAnswer((_) async => {'status': 'ok', 'source_id': 'guide.pdf'});
    when(() => mockApiClient.delete(any()))
        .thenAnswer((_) async => {'status': 'deleted', 'deleted_nodes': 24});

    final snap = await repository.fetchSources();
    expect(snap.sources, hasLength(1));
    expect(snap.sources.first.isStale, isTrue);
    expect(snap.queue, hasLength(1));
    expect(snap.queue.first.progress, 0.78);

    await repository.reindexSource(sourceId: 'guide.pdf', category: 'doc');
    verify(() => mockApiClient.post('/admin/sources/reindex', body: {
          'source_id': 'guide.pdf',
          'category': 'doc',
        })).called(1);

    await repository.deleteSource(sourceId: 'guide.pdf', category: 'doc');
    verify(() => mockApiClient
        .delete('/admin/sources?source_id=guide.pdf&category=doc')).called(1);
  });
}
