import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/data/artifact_export_repository.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_artifact_panel.dart';

const _notesArtifact = CodeArtifact(
  title: 'Notes',
  fileName: 'notes.md',
  language: 'markdown',
  code: '# Notes\n\nHello export.',
);

void _noop() {}

/// Records the export call and returns canned bytes (or throws),
/// standing in for the backend exporter.
class _FakeExportRepository implements ArtifactExportRepository {
  String? format;
  String? contentType;
  String? content;
  Object? error;

  @override
  Future<Uint8List> exportArtifact({
    required String format,
    required String title,
    required String content,
    required String contentType,
    Map<String, dynamic>? spec,
  }) async {
    this.format = format;
    this.contentType = contentType;
    this.content = content;
    final failure = error;
    if (failure != null) throw failure;
    return Uint8List.fromList([37, 80, 68, 70, 45]); // %PDF-
  }
}

/// path_provider platform fake that roots every directory in [root].
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getDownloadsPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

Widget _hostPanel(CodeArtifact artifact, _FakeExportRepository repository) {
  return ProviderScope(
    overrides: [
      openCodeArtifactLiveProvider.overrideWithValue(artifact),
      artifactExportRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(
        body: SizedBox(
          width: 520,
          child: CodeArtifactPanel(
            open: OpenCodeArtifact(artifact: artifact),
            onClose: _noop,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('export menu downloads the exported PDF through the panel',
      (WidgetTester tester) async {
    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('artifact_export_test'),
    );
    addTearDown(() async {
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    PathProviderPlatform.instance = _FakePathProvider(tempDir!.path);
    final repository = _FakeExportRepository();

    await tester.pumpWidget(_hostPanel(_notesArtifact, repository));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Export'), findsOneWidget);
    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();
    expect(find.text('PDF (.pdf)'), findsOneWidget);
    expect(find.text('Word (.docx)'), findsOneWidget);
    expect(find.text('Excel (.xlsx)'), findsOneWidget);
    expect(find.text('PowerPoint (.pptx)'), findsOneWidget);

    await tester.tap(find.text('PDF (.pdf)'));
    await tester.pumpAndSettle();

    expect(repository.format, 'pdf');
    expect(repository.contentType, 'markdown');
    expect(repository.content, '# Notes\n\nHello export.');
    // Like the download test, the file on disk is the contract (the
    // "Saved to …" SnackBar continuation chains on real IO).
    final saved = File('${tempDir.path}/notes.pdf');
    final exists = await tester.runAsync(() => saved.exists());
    expect(exists, isTrue);
    final bytes = await tester.runAsync(() => saved.readAsBytes());
    expect(bytes, [37, 80, 68, 70, 45]);
  });

  testWidgets('export failure shows a SnackBar and writes no file',
      (WidgetTester tester) async {
    final repository = _FakeExportRepository()
      ..error = Exception('Server error: 500');

    await tester.pumpWidget(_hostPanel(_notesArtifact, repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Word (.docx)'));
    await tester.pumpAndSettle();

    expect(find.text('Export failed. Please try again.'), findsOneWidget);
  });

  testWidgets('office envelope export menu shows only the matching format',
      (WidgetTester tester) async {
    final repository = _FakeExportRepository();
    const deckArtifact = CodeArtifact(
      title: 'Pitch Deck',
      fileName: 'pitch_deck.json',
      language: 'json',
      code: '{"format": "pptx", "title": "Pitch Deck", "slides": []}',
    );

    await tester.pumpWidget(_hostPanel(deckArtifact, repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();

    expect(find.text('PowerPoint (.pptx)'), findsOneWidget);
    expect(find.text('Word (.docx)'), findsNothing);
    expect(find.text('Excel (.xlsx)'), findsNothing);
    expect(find.text('PDF (.pdf)'), findsNothing);
  });

  // No "menu hidden" widget test for mermaid/svg artifacts: their
  // panels open on a WebView preview, which has no platform
  // implementation in widget tests. The gating itself is covered by
  // the artifactCanExport unit tests in
  // artifact_export_provider_test.dart.
}
