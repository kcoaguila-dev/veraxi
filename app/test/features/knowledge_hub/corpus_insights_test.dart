import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/data/corpus_insights_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/corpus_insights_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/corpus_briefing_panel.dart';

class MockApiClient extends Mock implements ApiClient {}

class FakeCorpusInsightsRepository extends CorpusInsightsRepository {
  FakeCorpusInsightsRepository()
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  Map<String, dynamic>? lastManifest;

  @override
  Future<CorpusBriefing> fetchBriefing() async {
    return CorpusBriefing.fromJson({
      'tenant': 'tenant-1',
      'generated_from': {
        'total_nodes': 12,
        'total_relationships': 9,
        'nodes_by_label': {'Entity': 12},
        'relationships_by_type': {'RELATED_TO': 9},
        'community_count': 1,
      },
      'top_communities': [
        {
          'id': '0',
          'size': 3,
          'top_entities': [
            {'name': 'Acme', 'type': 'Org', 'degree': 4},
          ],
        },
      ],
      'newest_entities': [
        {'name': 'Acme', 'type': 'Org', 'first_seen': '2026-01-01'},
      ],
      'contradiction_flags': [
        {
          'entity': 'Acme',
          'relation': 'HEADQUARTERED_IN',
          'targets': ['X', 'Y'],
        },
      ],
      'contradiction_rule': 'heuristic',
      'markdown': '# Corpus Briefing — tenant-1',
    });
  }

  @override
  Future<Map<String, dynamic>> ingestDbtManifest(
    Map<String, dynamic> manifest,
  ) async {
    lastManifest = manifest;
    return {'status': 'ok', 'nodes_written': 2, 'edges_written': 1};
  }

  @override
  Future<List<DbtDatasetMatch>> searchDatasets(String query) async {
    return [
      DbtDatasetMatch.fromJson({
        'name': 'users',
        'label': 'Dataset',
        'unique_id': 'model.proj.users',
        'matched_by': ['name'],
        'upstream': [
          {'unique_id': 'source.raw', 'name': 'raw_users', 'label': 'Dataset'},
        ],
        'downstream': [
          {
            'unique_id': 'model.dau',
            'name': 'daily_active_users',
            'label': 'Model'
          },
        ],
      }),
    ];
  }
}

ThemeData testTheme() {
  return ThemeData().copyWith(
    extensions: [
      AppThemeExtension(
        primaryGradientStart: Colors.blue,
        primaryGradientEnd: Colors.blueAccent,
        surfaceHighlight: Colors.grey.shade800,
        sidebarBackground: Colors.black,
        cardBackground: Colors.black54,
        dialogBackground: Colors.black87,
        borderColor: Colors.white24,
        borderColorStrong: Colors.white54,
        textTertiary: Colors.grey,
        iconColor: Colors.white70,
      ),
    ],
  );
}

void main() {
  group('CorpusInsightsRepository', () {
    late MockApiClient mockApiClient;
    late CorpusInsightsRepository repository;

    setUp(() {
      mockApiClient = MockApiClient();
      repository = CorpusInsightsRepository(apiClient: mockApiClient);
    });

    test('fetchBriefing parses counts, communities and markdown', () async {
      when(() => mockApiClient.get(any())).thenAnswer((_) async => {
            'tenant': 't',
            'generated_from': {
              'total_nodes': 5,
              'total_relationships': 4,
              'nodes_by_label': {},
              'relationships_by_type': {},
              'community_count': 0,
            },
            'top_communities': [],
            'newest_entities': [],
            'contradiction_flags': [],
            'contradiction_rule': '',
            'markdown': '# Corpus Briefing',
          });
      final briefing = await repository.fetchBriefing();
      expect(briefing.totalNodes, 5);
      expect(briefing.markdown, contains('Corpus Briefing'));
      verify(() => mockApiClient.get('/v1/corpus/briefing')).called(1);
    });

    test('ingestDbtManifest posts the manifest dict', () async {
      when(() => mockApiClient.post(any(), body: any(named: 'body')))
          .thenAnswer((_) async => {'status': 'ok', 'nodes_written': 1});
      await repository.ingestDbtManifest({'nodes': {}});
      verify(() => mockApiClient.post(
            '/v1/dbt/ingest',
            body: {
              'manifest': {'nodes': {}}
            },
          )).called(1);
    });

    test('searchDatasets encodes the query', () async {
      when(() => mockApiClient.get(any()))
          .thenAnswer((_) async => {'query': 'a b', 'matches': []});
      final matches = await repository.searchDatasets('a b');
      expect(matches, isEmpty);
      verify(() => mockApiClient.get('/v1/dbt/datasets?q=a+b')).called(1);
    });
  });

  group('CorpusBriefingPanel', () {
    testWidgets('renders briefing content and dbt lineage results',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final fake = FakeCorpusInsightsRepository();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          corpusInsightsRepositoryProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
          theme: testTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(child: CorpusBriefingPanel()),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Load the briefing via the refresh action.
      await tester.tap(find.byTooltip('Refresh briefing'));
      await tester.pumpAndSettle();
      expect(find.text('Corpus Briefing'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.textContaining('Community 0 (size 3)'), findsOneWidget);
      expect(find.textContaining('HEADQUARTERED_IN'), findsOneWidget);
      expect(find.text('Copy MD'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);

      // dbt dataset search.
      await tester.enterText(find.byType(TextField).first, 'users');
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.textContaining('users (Dataset'), findsOneWidget);
      expect(find.textContaining('Upstream: raw_users'), findsOneWidget);
      expect(find.textContaining('Downstream: daily_active_users'),
          findsOneWidget);
    });

    testWidgets('view model ingests manifest bytes', (tester) async {
      final fake = FakeCorpusInsightsRepository();
      final container = ProviderContainer(overrides: [
        corpusInsightsRepositoryProvider.overrideWithValue(fake),
      ]);
      addTearDown(container.dispose);
      final viewModel =
          container.read(corpusInsightsViewModelProvider.notifier);
      await viewModel.ingestManifestBytes(
        utf8.encode(jsonEncode({'nodes': {}, 'sources': {}})),
      );
      final state = container.read(corpusInsightsViewModelProvider);
      expect(state.manifestStatus, contains('Ingested 2 nodes'));
      expect(fake.lastManifest, isNotNull);
    });
  });
}
