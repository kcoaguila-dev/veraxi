import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/chat/data/artifact_export_repository.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_export_provider.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

class MockArtifactExportRepository extends Mock
    implements ArtifactExportRepository {}

void main() {
  late MockArtifactExportRepository repository;
  late ArtifactExportController controller;

  setUp(() {
    repository = MockArtifactExportRepository();
    controller = ArtifactExportController(repository);
  });

  tearDown(() => controller.dispose());

  void stubExport({Object? error}) {
    when(() => repository.exportArtifact(
          format: any(named: 'format'),
          title: any(named: 'title'),
          content: any(named: 'content'),
          contentType: any(named: 'contentType'),
          spec: any(named: 'spec'),
        )).thenAnswer((_) async {
      if (error != null) throw error;
      return Uint8List.fromList([1, 2, 3]);
    });
  }

  group('content mapping', () {
    test('markdown artifacts export as markdown, verbatim', () {
      const artifact = CodeArtifact(
        title: 'Notes',
        fileName: 'notes.md',
        language: 'markdown',
        code: '# Notes\n\nHello',
      );
      expect(artifactExportContentType(artifact), 'markdown');
      expect(artifactExportContent(artifact), '# Notes\n\nHello');
      expect(artifactCanExport(artifact), isTrue);
    });

    test('csv and json artifacts keep their content types', () {
      const csv = CodeArtifact(
        title: 'Data',
        fileName: 'data.csv',
        language: 'csv',
        code: 'a,b\n1,2',
      );
      const json = CodeArtifact(
        title: 'Spec',
        fileName: 'spec.json',
        language: 'json',
        code: '{"sheets": []}',
      );
      expect(artifactExportContentType(csv), 'csv');
      expect(artifactExportContentType(json), 'json');
    });

    test('plain code exports as a fenced markdown code block', () {
      const artifact = CodeArtifact(
        title: 'Hello world',
        fileName: 'hello_world.py',
        language: 'python',
        code: 'print("hi")',
      );
      expect(artifactExportContentType(artifact), 'code');
      expect(artifactExportContent(artifact), '```python\nprint("hi")\n```');
      expect(artifactCanExport(artifact), isTrue);
    });

    test('mermaid and svg artifacts are not exportable', () {
      const mermaid = CodeArtifact(
        title: 'Diagram',
        fileName: 'diagram.mmd',
        language: 'mermaid',
        code: 'graph TD; A-->B',
      );
      const svg = CodeArtifact(
        title: 'Icon',
        fileName: 'icon.svg',
        language: 'svg',
        code: '<svg></svg>',
      );
      expect(artifactCanExport(mermaid), isFalse);
      expect(artifactCanExport(svg), isFalse);
    });

    test('export file name swaps the extension for the format', () {
      const artifact = CodeArtifact(
        title: 'Notes',
        fileName: 'notes.md',
        language: 'markdown',
        code: '# Notes',
      );
      expect(
        artifactExportFileName(artifact, ArtifactExportFormat.pdf),
        'notes.pdf',
      );
      expect(
        artifactExportFileName(artifact, ArtifactExportFormat.docx),
        'notes.docx',
      );
    });
  });

  group('ArtifactExportController', () {
    test('success returns the document with name, bytes, and mime', () async {
      stubExport();
      const artifact = CodeArtifact(
        title: 'Notes',
        fileName: 'notes.md',
        language: 'markdown',
        code: '# Notes',
      );

      final exported =
          await controller.exportArtifact(artifact, ArtifactExportFormat.pdf);

      expect(exported, isNotNull);
      expect(exported!.fileName, 'notes.pdf');
      expect(exported.bytes, Uint8List.fromList([1, 2, 3]));
      expect(exported.mimeType, 'application/pdf');
      expect(controller.state.isExporting, isFalse);
      expect(controller.state.error, isNull);

      final captured = verify(() => repository.exportArtifact(
            format: captureAny(named: 'format'),
            title: captureAny(named: 'title'),
            content: captureAny(named: 'content'),
            contentType: captureAny(named: 'contentType'),
            spec: any(named: 'spec'),
          )).captured;
      expect(captured, ['pdf', 'Notes', '# Notes', 'markdown']);
    });

    test('code artifacts are sent as markdown content', () async {
      stubExport();
      const artifact = CodeArtifact(
        title: 'Hello world',
        fileName: 'hello_world.py',
        language: 'python',
        code: 'print("hi")',
      );

      final exported = await controller.exportArtifact(
        artifact,
        ArtifactExportFormat.docx,
      );

      expect(exported!.fileName, 'hello_world.docx');
      final captured = verify(() => repository.exportArtifact(
            format: any(named: 'format'),
            title: any(named: 'title'),
            content: captureAny(named: 'content'),
            contentType: captureAny(named: 'contentType'),
            spec: any(named: 'spec'),
          )).captured;
      expect(captured, ['```python\nprint("hi")\n```', 'markdown']);
    });

    test('failure records a friendly error and returns null', () async {
      stubExport(error: Exception('Server error: 413'));
      const artifact = CodeArtifact(
        title: 'Notes',
        fileName: 'notes.md',
        language: 'markdown',
        code: '# Notes',
      );

      final exported =
          await controller.exportArtifact(artifact, ArtifactExportFormat.pdf);

      expect(exported, isNull);
      expect(controller.state.isExporting, isFalse);
      expect(controller.state.error, 'This artifact is too large to export.');
    });
  });
}
