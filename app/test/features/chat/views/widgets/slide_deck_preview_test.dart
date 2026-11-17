import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_export_provider.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';
import 'package:veraxi_app/features/chat/view_models/slide_deck_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_artifact_card.dart';
import 'package:veraxi_app/features/chat/views/widgets/slide_deck_preview.dart';

const _sampleDeckJson = '''
{
  "format": "pptx",
  "title": "Hello World",
  "slides": [
    {
      "title": "Hello",
      "theme": "dark",
      "accent_color": "#D98A2B"
    },
    {
      "title": "World",
      "subtitle": "Second slide",
      "bullets": ["Point A", "Point B"],
      "theme": "light",
      "accent_color": "#D98A2B"
    }
  ]
}
''';

void main() {
  group('SlideDeck parsing and CodeArtifact classification', () {
    test('CodeArtifact.fromCode classifies pptx JSON envelope as slides', () {
      final artifact = CodeArtifact.fromCode(
        language: 'json',
        code: _sampleDeckJson,
      );
      expect(artifact.previewKind, CodePreviewKind.slides);
      expect(artifact.isPreviewable, isTrue);
      expect(artifact.title, 'Hello World');
      expect(artifactCanExport(artifact), isTrue);
      expect(
        availableExportFormats(artifact),
        const [ArtifactExportFormat.pptx],
      );
    });

    test('plain JSON without slides stays CodePreviewKind.none', () {
      final artifact = CodeArtifact.fromCode(
        language: 'json',
        code: '{"hello": "world"}',
      );
      expect(artifact.previewKind, CodePreviewKind.none);
      expect(artifact.isPreviewable, isFalse);
    });

    test('appendSlideToDeckJson adds a slide and preserves envelope fields', () {
      final updated = appendSlideToDeckJson(_sampleDeckJson);
      expect(updated, isNotNull);
      final decoded = jsonDecode(updated!) as Map<String, dynamic>;
      expect(decoded['format'], 'pptx');
      expect(decoded['title'], 'Hello World');
      final slides = decoded['slides'] as List<dynamic>;
      expect(slides.length, 3);
      expect((slides[2] as Map<String, dynamic>)['title'], 'Slide 3');
    });
  });

  group('CodeArtifactCard for slides', () {
    testWidgets('shows slideshow icon and slide count subtitle', (tester) async {
      final artifact = CodeArtifact.fromCode(
        language: 'json',
        code: _sampleDeckJson,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeArtifactCard(
              artifact: artifact,
              onTap: () {},
            ),
          ),
        ),
      );
      expect(find.text('Hello World'), findsOneWidget);
      expect(find.text('SLIDES · 2 slides'), findsOneWidget);
      expect(find.byIcon(Icons.slideshow_outlined), findsOneWidget);
    });
  });

  group('SlideDeckPreview widget', () {
    testWidgets('renders thumbnails, navigates slides, and triggers onAddSlide',
        (tester) async {
      final deck = parseSlideDeckFromJson(_sampleDeckJson)!;
      var addCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 600,
              child: SlideDeckPreview(
                deck: deck,
                onAddSlide: () => addCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('Hello'), findsWidgets);

      // Navigate to slide 2 via Next button
      await tester.tap(find.byTooltip('Next slide'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('Second slide'), findsOneWidget);
      expect(find.text('Point A'), findsOneWidget);

      // Tap Add slide button
      await tester.tap(find.text('Add slide'));
      await tester.pump();
      expect(addCalled, isTrue);
    });
  });
}
