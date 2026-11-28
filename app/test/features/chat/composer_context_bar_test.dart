import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_chat_composer.dart';
import 'package:veraxi_app/features/chat/views/widgets/composer_context_bar.dart';

void main() {
  Widget buildHarness({
    List<IndexedRepoItem> repos = const [],
    String? selectedRepo,
  }) {
    return ProviderScope(
      overrides: [
        indexedReposProvider.overrideWith((ref) => repos),
        selectedIndexedRepoProvider.overrideWith((ref) => selectedRepo),
      ],
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: CodeChatComposer(
                  headerSlot: const ComposerContextBar(),
                  isLoading: false,
                  onSend: (_, {attachments}) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('Branch/worktree popover toggles new worktree label and state',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    expect(find.text('main'), findsOneWidget);
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();

    expect(find.text('Work in a New Worktree'), findsOneWidget);
    expect(find.text('Keeps your checkout untouched'), findsOneWidget);

    await tester.tap(find.text('Work in a New Worktree'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ComposerContextBar)),
    );
    expect(container.read(codeWorktreeProvider), isTrue);
    expect(find.text('main · new worktree'), findsOneWidget);
  });

  testWidgets('Repo popover searches and selects indexed repos',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const repos = [
      IndexedRepoItem(
        repoKey: 'veraxi-ymmp',
        displayName: 'veraxi-ymmp',
        fileCount: 120,
        symbolCount: 450,
      ),
      IndexedRepoItem(
        repoKey: 'manimgx',
        displayName: 'ManimGX',
        fileCount: 42,
        symbolCount: 180,
      ),
    ];

    await tester.pumpWidget(buildHarness(repos: repos));
    await tester.pumpAndSettle();

    await tester.tap(find.text('No repo'));
    await tester.pumpAndSettle();

    expect(find.text('Search Projects'), findsOneWidget);
    expect(find.text('veraxi-ymmp'), findsOneWidget);
    expect(find.text('ManimGX'), findsOneWidget);

    final searchField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Search Projects',
    );
    await tester.enterText(searchField, 'manim');
    await tester.pumpAndSettle();

    expect(find.text('ManimGX'), findsOneWidget);
    expect(find.text('veraxi-ymmp'), findsNothing);

    await tester.tap(find.text('ManimGX'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ComposerContextBar)),
    );
    expect(container.read(selectedIndexedRepoProvider), 'manimgx');
    expect(
      container.read(codeSelectedSourcesProvider).repoKeys,
      {'manimgx'},
    );
  });

  testWidgets('Local Permissions popover switches Default to Turbo',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    expect(find.text('Default'), findsOneWidget);
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();

    expect(find.text('Local Permissions'), findsOneWidget);
    expect(find.text('Request Review'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Turbo'), findsOneWidget);
    expect(find.text('Run all commands without restrictions.'), findsOneWidget);

    await tester.tap(find.text('Turbo'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ComposerContextBar)),
    );
    expect(container.read(codeAutonomyModeProvider), 'autonomous');
    expect(find.text('Turbo'), findsOneWidget);
  });

  testWidgets('CodeChatComposer shows Groq icon for openai/gpt-oss-20b',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeChatComposer)),
    );
    await container
        .read(modelSelectionProvider.notifier)
        .selectModel('openai/gpt-oss-20b');
    await tester.pumpAndSettle();

    expect(find.text('openai/gpt-oss-20b'), findsOneWidget);

    final groqSvg = find.byWidgetPredicate(
      (w) =>
          w is SvgPicture &&
          w.bytesLoader is SvgAssetLoader &&
          (w.bytesLoader as SvgAssetLoader).assetName == 'assets/icons/groq.svg',
    );
    final openaiSvg = find.byWidgetPredicate(
      (w) =>
          w is SvgPicture &&
          w.bytesLoader is SvgAssetLoader &&
          (w.bytesLoader as SvgAssetLoader).assetName ==
              'assets/icons/openai.svg',
    );

    expect(groqSvg, findsOneWidget);
    expect(openaiSvg, findsNothing);
  });
}
