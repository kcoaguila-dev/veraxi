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

    test('office spec envelope exports via its spec and title', () async {
      stubExport();
      // The block the create_office_artifact tool returns, as it
      // arrives in a chat message.
      const message = 'Here is your pitch deck:\n\n'
          '```json\n'
          '{\n'
          '  "slides": [{"title": "Vision", "bullets": ["Problem"]}],\n'
          '  "format": "pptx",\n'
          '  "title": "Pitch Deck"\n'
          '}\n'
          '```';
      final artifacts = extractCodeArtifacts(message);
      expect(artifacts, hasLength(1));
      final artifact = artifacts.single;
      expect(artifact.language, 'json');

      final envelope = parseOfficeArtifactEnvelope(artifact);
      expect(envelope, isNotNull);
      expect(envelope!.format, 'pptx');
      expect(envelope.title, 'Pitch Deck');
      expect(envelope.spec, {
        'slides': [
          {
            'title': 'Vision',
            'bullets': ['Problem'],
          }
        ],
      });
      expect(envelope.content, isNull);

      final exported = await controller.exportArtifact(
        artifact,
        ArtifactExportFormat.pptx,
      );

      expect(exported, isNotNull);
      expect(exported!.fileName, 'Pitch_Deck.pptx');
      final captured = verify(() => repository.exportArtifact(
            format: captureAny(named: 'format'),
            title: captureAny(named: 'title'),
            content: captureAny(named: 'content'),
            contentType: captureAny(named: 'contentType'),
            spec: captureAny(named: 'spec'),
          )).captured;
      expect(captured, [
        'pptx',
        'Pitch Deck',
        '',
        'json',
        {
          'slides': [
            {
              'title': 'Vision',
              'bullets': ['Problem'],
            }
          ],
        },
      ]);
    });

    test('office content envelope exports its wrapped body', () async {
      stubExport();
      const artifact = CodeArtifact(
        title: 'Json code',
        fileName: null,
        language: 'json',
        code: '{"format": "pdf", "title": "Status Report", '
            '"content_type": "markdown", "content": "# Status\\n\\nGreen."}',
      );

      final envelope = parseOfficeArtifactEnvelope(artifact);
      expect(envelope, isNotNull);
      expect(envelope!.spec, isNull);
      expect(envelope.content, '# Status\n\nGreen.');
      expect(envelope.contentType, 'markdown');

      final exported = await controller.exportArtifact(
        artifact,
        ArtifactExportFormat.pdf,
      );

      expect(exported!.fileName, 'Status_Report.pdf');
      final captured = verify(() => repository.exportArtifact(
            format: any(named: 'format'),
            title: captureAny(named: 'title'),
            content: captureAny(named: 'content'),
            contentType: captureAny(named: 'contentType'),
            spec: any(named: 'spec'),
          )).captured;
      expect(captured, ['Status Report', '# Status\n\nGreen.', 'markdown']);
    });

    test('plain json artifacts are not office envelopes', () {
      const artifact = CodeArtifact(
        title: 'Config',
        fileName: 'config.json',
        language: 'json',
        code: '{"theme": "dark", "fontSize": 14}',
      );
      expect(parseOfficeArtifactEnvelope(artifact), isNull);

      const broken = CodeArtifact(
        title: 'Json code',
        fileName: null,
        language: 'json',
        code: '{"slides": [',
      );
      expect(parseOfficeArtifactEnvelope(broken), isNull);
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

    test('availableExportFormats restricts office envelopes to matching format',
        () {
      const deck = CodeArtifact(
        title: 'Deck',
        fileName: 'deck.json',
        language: 'json',
        code: '{"format": "pptx", "title": "Deck", "slides": []}',
      );
      expect(availableExportFormats(deck), [ArtifactExportFormat.pptx]);

      const sheetWithoutFormat = CodeArtifact(
        title: 'Sheet',
        fileName: 'sheet.json',
        language: 'json',
        code: '{"sheets": [{"name": "S1", "headers": ["A"], "rows": []}]}',
      );
      expect(
        availableExportFormats(sheetWithoutFormat),
        [ArtifactExportFormat.xlsx],
      );

      const plainJson = CodeArtifact(
        title: 'Config',
        fileName: 'config.json',
        language: 'json',
        code: '{"theme": "dark"}',
      );
      expect(availableExportFormats(plainJson), ArtifactExportFormat.values);
    });
  });
}
