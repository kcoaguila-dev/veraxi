import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/data/evals_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/tabs/evidence_evals_panel.dart';

class FakeEvalsRepository extends EvalsRepository {
  FakeEvalsRepository()
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  Object? lastDataset;
  Map<String, dynamic>? lastRankings;

  @override
  Future<AblationReport> runAblation({
    required Object dataset,
    required Map<String, dynamic> rankings,
    int k = 5,
  }) async {
    lastDataset = dataset;
    lastRankings = rankings;
    return AblationReport.fromJson({
      'dataset': 'typed-dataset',
      'k': 5,
      'configurations': {
        'vector_only': {
          'overall': {
            'case_count': 1,
            'recall_at_k': 0.5,
            'hit_rate': 1.0,
            'grounding_score': null,
          },
          'by_query_type': {
            'lookup': {
              'case_count': 1,
              'recall_at_k': 0.5,
              'hit_rate': 1.0,
              'grounding_score': null,
            },
          },
          'cases': [],
        },
        'hybrid_with_graph': {
          'overall': {
            'case_count': 1,
            'recall_at_k': 1.0,
            'hit_rate': 1.0,
            'grounding_score': 0.9,
          },
          'by_query_type': {
            'lookup': {
              'case_count': 1,
              'recall_at_k': 1.0,
              'hit_rate': 1.0,
              'grounding_score': 0.9,
            },
          },
          'cases': [],
        },
      },
    });
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
  testWidgets('runs ablation and renders per-type table with n/a grounding',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fake = FakeEvalsRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        evalsRepositoryProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(child: EvidenceEvalsPanel()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Evidence Evals — Retrieval Ablation'), findsOneWidget);

    await tester.tap(find.text('Run Ablation'));
    await tester.pumpAndSettle();

    expect(fake.lastRankings, isNotNull);
    expect(find.text('Overall'), findsOneWidget);
    expect(find.text('lookup'), findsOneWidget);
    expect(find.text('vector_only'), findsWidgets);
    expect(find.text('hybrid_with_graph'), findsWidgets);
    expect(find.text('0.500'), findsWidgets);
    expect(find.text('1.000'), findsWidgets);
    // Grounding absent for vector_only → n/a, never an invented 0.
    expect(find.text('n/a'), findsWidgets);
    expect(find.text('0.900'), findsWidgets);
  });

  testWidgets('invalid JSON shows a local error and never calls the backend',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fake = FakeEvalsRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        evalsRepositoryProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(child: EvidenceEvalsPanel()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'not json');
    await tester.tap(find.text('Run Ablation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Invalid JSON'), findsOneWidget);
    expect(fake.lastRankings, isNull);
  });
}
