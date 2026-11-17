import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/data/memory_repository.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/memory_tab.dart';

class FakeMemoryRepository extends MemoryRepository {
  FakeMemoryRepository()
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  final List<UserMemory> stored = [
    const UserMemory(
      id: 'm1',
      content: 'Prefers concise answers',
      source: 'manual',
      validFrom: '2026-11-01T00:00:00Z',
    ),
    const UserMemory(
      id: 'm2',
      content: 'Works on the Veraxi backend',
      source: 'chat',
      validFrom: '2026-11-01T00:00:00Z',
      validTo: '2026-11-10T00:00:00Z',
    ),
  ];
  final List<String> deletedIds = [];
  final List<String> expiredIds = [];

  @override
  Future<List<UserMemory>> getMemories() async => List.of(stored);

  @override
  Future<UserMemory> createMemory(String content) async {
    final created = UserMemory(id: 'm-new', content: content);
    stored.insert(0, created);
    return created;
  }

  @override
  Future<UserMemory> updateMemory(String id, String content) async {
    return UserMemory(id: id, content: content, source: 'manual');
  }

  @override
  Future<UserMemory> expireMemory(String id) async {
    expiredIds.add(id);
    return UserMemory(
      id: id,
      content: stored.firstWhere((m) => m.id == id).content,
      validTo: '2026-11-18T00:00:00Z',
    );
  }

  @override
  Future<void> deleteMemory(String id) async {
    deletedIds.add(id);
    stored.removeWhere((m) => m.id == id);
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
        iconColor: Colors.white,
      ),
    ],
  );
}

Widget wrapTab(FakeMemoryRepository repository) {
  return ProviderScope(
    overrides: [
      memoryRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(
      theme: testTheme(),
      home: const Scaffold(
        body: SingleChildScrollView(child: MemoryTab()),
      ),
    ),
  );
}

void main() {
  group('MemoryTab', () {
    late FakeMemoryRepository repository;

    setUp(() {
      repository = FakeMemoryRepository();
    });

    testWidgets('lists memories with source and validity', (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      expect(find.text('Memory'), findsOneWidget);
      expect(find.text('Add a Memory'), findsOneWidget);
      expect(find.text('Your Memories'), findsOneWidget);
      expect(find.text('Prefers concise answers'), findsOneWidget);
      expect(find.text('Works on the Veraxi backend'), findsOneWidget);
      expect(find.text('manual'), findsOneWidget);
      expect(find.text('chat'), findsOneWidget);
      expect(find.text('Valid'), findsOneWidget);
      expect(find.text('Expired 2026-11-10'), findsOneWidget);
      // Expire is only offered for still-valid memories.
      expect(find.text('Expire'), findsOneWidget);
      expect(find.text('Delete'), findsNWidgets(2));
    });

    testWidgets('adding a memory shows it in the list', (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Lives in Tokyo');
      await tester.tap(find.text('Add Memory'));
      await tester.pumpAndSettle();

      expect(find.text('Lives in Tokyo'), findsOneWidget);
    });

    testWidgets('delete removes the memory via the repository', (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete').first);
      await tester.pumpAndSettle();

      expect(repository.deletedIds, ['m1']);
      expect(find.text('Prefers concise answers'), findsNothing);
    });

    testWidgets('expire soft-expires the memory via the repository',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Expire'));
      await tester.pumpAndSettle();

      expect(repository.expiredIds, ['m1']);
      expect(find.text('Expired 2026-11-18'), findsWidgets);
    });
  });
}
