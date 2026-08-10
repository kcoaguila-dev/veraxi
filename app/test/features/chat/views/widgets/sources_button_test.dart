import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_button.dart';

// ---------------------------------------------------------------------------
// Helpers: build ToolEvent payloads matching what the backend actually sends.
// ---------------------------------------------------------------------------

/// Real artifact format from merge_rank + execute_tools:
/// merge_rank replaces original source URLs with "vector"/"graph" labels.
/// The real URL lives in payload.url (stored by WebHit).
Map<String, dynamic> _webHitArtifact({
  required String url,
  required String title,
  String content = 'Some extracted content',
}) {
  return {
    'id': 'some-uuid-123',
    'payload': {
      'text': content,
      'title': title,
      'url': url,
    },
    'sources': ['vector'], // merge_rank always replaces the URL with "vector"
  };
}

/// Qdrant vector hit format (no real URL, just a text chunk).
Map<String, dynamic> _qdrantHitArtifact({
  required String text,
  String title = '',
}) {
  return {
    'id': 'qdrant-id-456',
    'payload': {
      'text': text,
      'title': title,
      // No 'url' key — pure internal knowledge-base chunk
    },
    'sources': ['vector'],
  };
}

/// Legacy flat-URL format (used in unit tests before the fix — NOT how
/// the backend sends data in production, but should still be handled).
Map<String, dynamic> _flatUrlArtifact({
  required String url,
  required String title,
}) {
  return {
    'url': url,
    'title': title,
  };
}

/// Flat 'link' field format (SearxNG search-engine result format).
Map<String, dynamic> _flatLinkArtifact({
  required String link,
  required String title,
}) {
  return {
    'link': link,
    'title': title,
  };
}

// ---------------------------------------------------------------------------
// Unit tests for the static extraction helpers
// ---------------------------------------------------------------------------

void main() {
  group('SourcesButton.extractSources — real merge_rank artifact format', () {
    // --- THE BUG REGRESSION TEST ---
    // Before the fix, sources[0] = "vector" was returned as the URL,
    // which failed domain validation and fell back to "Internal Database".
    test(
      'extractSources reads URL from payload.url when sources contains "vector"',
      () {
        final toolEvent = ToolEvent(
          id: 'tool-1',
          name: 'web_search',
          isComplete: true,
          result: [
            _webHitArtifact(
              url: 'https://www.technews-daily.com/articles/ai-roundup',
              title: 'AI Weekly Roundup: Top Stories',
            ),
          ],
        );

        final message = ChatMessage(
          role: 'assistant',
          content: 'Here is some information.',
          toolEvents: [toolEvent],
        );

        final sources = SourcesButton.extractSources(message);
        expect(sources.length, 1);
        // Must be the real URL, NOT "vector" or empty
        expect(sources[0]['url'], 'https://www.technews-daily.com/articles/ai-roundup');
        expect(sources[0]['title'], contains('AI Weekly'));
      },
    );

    test(
      'extractSources handles multiple web results all with sources=["vector"]',
      () {
        final toolEvent = ToolEvent(
          id: 'tool-2',
          name: 'web_search',
          isComplete: true,
          result: [
            _webHitArtifact(
              url: 'https://techcrunch.com/ai-news',
              title: 'Latest AI News',
            ),
            _webHitArtifact(
              url: 'https://arxiv.org/abs/1234.5678',
              title: 'A New Model Paper',
            ),
          ],
        );

        final message = ChatMessage(
          role: 'assistant',
          content: 'Here is the news.',
          toolEvents: [toolEvent],
        );

        final sources = SourcesButton.extractSources(message);
        expect(sources.length, 2);
        expect(sources[0]['url'], 'https://techcrunch.com/ai-news');
        expect(sources[1]['url'], 'https://arxiv.org/abs/1234.5678');
      },
    );

    test(
      'Qdrant-only hit with no URL returns empty url (Internal Database is correct)',
      () {
        final toolEvent = ToolEvent(
          id: 'tool-3',
          name: 'search_vectors',
          isComplete: true,
          result: [
            _qdrantHitArtifact(
              text: 'Architecture decision: use RRF for merge ranking.',
              title: 'ADR-001',
            ),
          ],
        );

        final message = ChatMessage(
          role: 'assistant',
          content: 'Based on the architecture docs.',
          toolEvents: [toolEvent],
        );

        final sources = SourcesButton.extractSources(message);
        expect(sources.length, 1);
        // No URL — correctly shows as internal
        expect(sources[0]['url'], isEmpty);
        expect(sources[0]['title'], 'ADR-001');
      },
    );
  });

  group('SourcesButton.extractSources — legacy and edge-case formats', () {
    test('flat url field (legacy format) is still supported', () {
      final toolEvent = ToolEvent(
        id: 'tool-4',
        name: 'web_search',
        isComplete: true,
        result: [
          _flatUrlArtifact(
            url: 'https://example.com/news1',
            title: 'Test News 1',
          ),
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Here is the news.',
        toolEvents: [toolEvent],
      );

      final sources = SourcesButton.extractSources(message);
      expect(sources.length, 1);
      expect(sources[0]['url'], 'https://example.com/news1');
    });

    test('flat link field (SearxNG format) is supported', () {
      final toolEvent = ToolEvent(
        id: 'tool-5',
        name: 'web_search',
        isComplete: true,
        result: [
          _flatLinkArtifact(
            link: 'https://anotherexample.com/article',
            title: 'Test Article',
          ),
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Here is the article.',
        toolEvents: [toolEvent],
      );

      final sources = SourcesButton.extractSources(message);
      expect(sources.length, 1);
      expect(sources[0]['url'], 'https://anotherexample.com/article');
    });

    test('payload.link is used when payload.url is absent', () {
      final toolEvent = ToolEvent(
        id: 'tool-6',
        name: 'web_search',
        isComplete: true,
        result: [
          {
            'id': 'xyz',
            'payload': {
              'title': 'Article via link field',
              'link': 'https://link-field-example.com/page',
            },
            'sources': ['vector'],
          },
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Some content.',
        toolEvents: [toolEvent],
      );

      final sources = SourcesButton.extractSources(message);
      expect(sources.length, 1);
      expect(sources[0]['url'], 'https://link-field-example.com/page');
    });

    test('sources array with http URL is used as last fallback', () {
      final toolEvent = ToolEvent(
        id: 'tool-7',
        name: 'web_search',
        isComplete: true,
        result: [
          {
            'id': 'xyz',
            'payload': {'title': 'No URL in payload'},
            'sources': ['https://fallback-from-sources.com/page'],
          },
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Content.',
        toolEvents: [toolEvent],
      );

      final sources = SourcesButton.extractSources(message);
      expect(sources.length, 1);
      expect(sources[0]['url'], 'https://fallback-from-sources.com/page');
    });

    test('sources array with non-http value like "vector" is NOT used as URL', () {
      final toolEvent = ToolEvent(
        id: 'tool-8',
        name: 'search_vectors',
        isComplete: true,
        result: [
          {
            'id': 'xyz',
            'payload': {'title': 'Internal chunk', 'text': 'Some text'},
            'sources': ['vector'], // must not be treated as a URL
          },
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Content.',
        toolEvents: [toolEvent],
      );

      final sources = SourcesButton.extractSources(message);
      expect(sources.length, 1);
      // url should be empty — "vector" is not a valid URL
      expect(sources[0]['url'], isEmpty);
    });

    test('deduplicates sources with the same URL', () {
      final toolEvent = ToolEvent(
        id: 'tool-9',
        name: 'web_search',
        isComplete: true,
        result: [
          _webHitArtifact(
              url: 'https://example.com', title: 'Duplicate A'),
          _webHitArtifact(
              url: 'https://example.com', title: 'Duplicate B'),
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Content.',
        toolEvents: [toolEvent],
      );

      final sources = SourcesButton.extractSources(message);
      expect(sources.length, 1); // deduplicated
    });

    test('items with no title and no url are excluded', () {
      final toolEvent = ToolEvent(
        id: 'tool-10',
        name: 'web_search',
        isComplete: true,
        result: [
          {'payload': {}, 'sources': ['vector']}, // completely empty
          _webHitArtifact(url: 'https://valid.com', title: 'Valid'),
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Content.',
        toolEvents: [toolEvent],
      );

      final sources = SourcesButton.extractSources(message);
      expect(sources.length, 1); // only the valid one
      expect(sources[0]['url'], 'https://valid.com');
    });
  });

  group('SourcesButton widget rendering', () {
    testWidgets('renders correct source count for web search results', (WidgetTester tester) async {
      final toolEvent = ToolEvent(
        id: 'tool-widget-1',
        name: 'web_search',
        isComplete: true,
        result: [
          _webHitArtifact(url: 'https://a.com', title: 'A'),
          _webHitArtifact(url: 'https://b.com', title: 'B'),
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Here is the news.',
        toolEvents: [toolEvent],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourcesButton(
              message: message,
              onSourceClicked: () {},
            ),
          ),
        ),
      );

      expect(find.text('2 sources'), findsOneWidget);
    });

    testWidgets('fires callback on tap', (WidgetTester tester) async {
      final toolEvent = ToolEvent(
        id: 'tool-widget-2',
        name: 'web_search',
        isComplete: true,
        result: [
          _webHitArtifact(url: 'https://example.com', title: 'Example'),
        ],
      );

      final message = ChatMessage(
        role: 'assistant',
        content: 'Content.',
        toolEvents: [toolEvent],
      );

      bool callbackFired = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourcesButton(
              message: message,
              onSourceClicked: () => callbackFired = true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('1 source'));
      expect(callbackFired, isTrue);
    });

    testWidgets('renders nothing when no sources are found', (WidgetTester tester) async {
      final message = ChatMessage(
        role: 'assistant',
        content: 'A simple answer with no tool calls.',
        toolEvents: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourcesButton(
              message: message,
              onSourceClicked: () {},
            ),
          ),
        ),
      );

      expect(find.byType(SourcesButton), findsOneWidget);
      // No "sources" label — widget renders as SizedBox.shrink
      expect(find.textContaining('source'), findsNothing);
    });
  });
}
