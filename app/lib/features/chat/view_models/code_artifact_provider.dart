import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/slide_deck_provider.dart';

/// A single fenced code block from an assistant message, presented the way
/// Claude presents a created file: a compact card in the chat flow that
/// opens the full code in a panel on the right side of the screen.
///
/// This is a view-state model only. The code itself always comes from the
/// message markdown; nothing here talks to a repository.
class CodeArtifact {
  /// Human-readable title shown on the card and in the panel header,
  /// e.g. `Hello world` for `hello_world.py`.
  final String title;

  /// The file name the assistant mentioned for this block, when one could
  /// be found (e.g. `hello_world.py`). Null for anonymous snippets.
  final String? fileName;

  /// Normalized language id used for syntax highlighting,
  /// e.g. `python`, `dart`, `javascript`.
  final String language;

  /// The raw code, without the surrounding markdown fences.
  final String code;

  const CodeArtifact({
    required this.title,
    required this.fileName,
    required this.language,
    required this.code,
  });

  factory CodeArtifact.fromCode({
    required String language,
    required String code,
    String? fileName,
  }) {
    final normalized = normalizeCodeLanguage(language);
    final deck = (normalized == 'json' ||
            (fileName != null && fileName.toLowerCase().endsWith('.json')))
        ? parseSlideDeckFromJson(code)
        : null;
    return CodeArtifact(
      title: deck?.title ??
          (fileName != null
              ? humanizeFileName(fileName)
              : '${codeLanguageDisplayName(normalized)} code'),
      fileName: fileName,
      language: normalized,
      code: code,
    );
  }

  /// Short uppercase badge shown under the title, e.g. `PY` for a Python
  /// file — mirrors the `PY` label under Claude's file cards.
  String get extensionLabel {
    final name = fileName;
    if (name != null) {
      final dot = name.lastIndexOf('.');
      if (dot >= 0 && dot < name.length - 1) {
        return name.substring(dot + 1).toUpperCase();
      }
    }
    return switch (language) {
      'python' => 'PY',
      'javascript' => 'JS',
      'typescript' => 'TS',
      'plaintext' => 'TXT',
      _ => language.toUpperCase(),
    };
  }

  int get lineCount =>
      code.isEmpty ? 0 : '\n'.allMatches(code.trimRight()).length + 1;

  /// The name this artifact downloads under: its real file name when
  /// it has one, otherwise `artifact.<ext>` derived from the language.
  String get downloadFileName {
    final name = fileName;
    if (name != null && name.isNotEmpty) return name;
    final ext = switch (language) {
      'python' => 'py',
      'javascript' => 'js',
      'typescript' => 'ts',
      'markdown' => 'md',
      'plaintext' => 'txt',
      'bash' => 'sh',
      'cs' => 'cs',
      _ => language,
    };
    return 'artifact.$ext';
  }

  /// Lowercase file extension without the dot, or null when the block
  /// has no file name.
  String? get fileExtension {
    final name = fileName;
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  /// Language id the syntax highlighter understands. Highlight.js treats
  /// HTML and SVG as XML, everything else uses the normalized id.
  String get highlightLanguage => switch (language) {
        'html' || 'svg' => 'xml',
        _ => language,
      };

  /// How this artifact can be live-previewed in the panel, the way
  /// Claude's artifact pane previews HTML, React, SVG, Mermaid, and
  /// Markdown while plain code stays a highlighted listing.
  CodePreviewKind get previewKind {
    final ext = fileExtension;
    if (language == 'svg' || ext == 'svg') return CodePreviewKind.svg;
    if (language == 'xml' && code.trimLeft().startsWith('<svg')) {
      return CodePreviewKind.svg;
    }
    if (language == 'html' ||
        language == 'xml' ||
        ext == 'html' ||
        ext == 'htm') {
      return CodePreviewKind.html;
    }
    if (language == 'mermaid' || ext == 'mmd') return CodePreviewKind.mermaid;
    if (language == 'markdown' || ext == 'md' || ext == 'markdown') {
      return CodePreviewKind.markdown;
    }
    if (language == 'jsx' ||
        language == 'tsx' ||
        ext == 'jsx' ||
        ext == 'tsx') {
      return CodePreviewKind.react;
    }
    if ((language == 'javascript' || language == 'typescript') &&
        _looksLikeReactComponent(code)) {
      return CodePreviewKind.react;
    }
    if ((language == 'json' || ext == 'json') &&
        parseSlideDeckFromJson(code) != null) {
      return CodePreviewKind.slides;
    }
    return CodePreviewKind.none;
  }

  bool get isPreviewable => previewKind != CodePreviewKind.none;

  @override
  bool operator ==(Object other) =>
      other is CodeArtifact &&
      other.title == title &&
      other.fileName == fileName &&
      other.language == language &&
      other.code == code;

  @override
  int get hashCode => Object.hash(title, fileName, language, code);
}

/// The kinds of live preview the artifact panel supports, mirroring the
/// set Claude renders in its artifact pane. Everything else is
/// [CodePreviewKind.none] and shows as highlighted code only.
enum CodePreviewKind {
  none,
  html,
  svg,
  mermaid,
  react,
  markdown,
  slides;

  /// Label for the preview toggle / panel subtitle, e.g. `HTML`.
  String get label => switch (this) {
        CodePreviewKind.none => '',
        CodePreviewKind.html => 'HTML',
        CodePreviewKind.svg => 'SVG',
        CodePreviewKind.mermaid => 'Mermaid',
        CodePreviewKind.react => 'React',
        CodePreviewKind.markdown => 'Markdown',
        CodePreviewKind.slides => 'Slides',
      };
}

final RegExp _jsxTagPattern = RegExp(r'<[A-Za-z][A-Za-z0-9]*(\s[^>]*)?/?>');

/// Conservative React heuristic for plain `javascript` / `typescript`
/// blocks: an exported (or React-referencing) component plus JSX markup.
/// A plain JS snippet with neither stays a code listing, not a preview.
bool _looksLikeReactComponent(String code) {
  final hasJsx = _jsxTagPattern.hasMatch(code);
  if (!hasJsx) return false;
  return code.contains('export default') ||
      code.contains('React') ||
      code.contains('useState');
}

/// The artifact open in the right-side panel: a snapshot taken when
/// its card was tapped, plus the coordinates needed to follow the
/// artifact's live content while its message is still streaming.
///
/// The snapshot is the fallback whenever live resolution is impossible
/// (message gone, thread switched, block not extracted yet).
class OpenCodeArtifact {
  /// The artifact as it was when the card was tapped.
  final CodeArtifact artifact;

  /// Thread the artifact was opened from.
  final String? threadId;

  /// Index of the source message in `ChatState.messages` at tap time.
  /// Messages only append within a thread, so the index stays valid
  /// for the life of the panel. Null when the message could not be
  /// located (the snapshot is then all the panel has).
  final int? messageIndex;

  /// Index of this artifact within its message's extracted artifacts.
  final int artifactIndex;

  const OpenCodeArtifact({
    required this.artifact,
    this.threadId,
    this.messageIndex,
    this.artifactIndex = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is OpenCodeArtifact &&
      other.artifact == artifact &&
      other.threadId == threadId &&
      other.messageIndex == messageIndex &&
      other.artifactIndex == artifactIndex;

  @override
  int get hashCode =>
      Object.hash(artifact, threadId, messageIndex, artifactIndex);
}

/// The artifact currently open in the panel, or null when the panel
/// is closed. Set by tapping a [CodeArtifact] card in a message;
/// cleared by the panel's close button or when the chat is emptied.
final openCodeArtifactProvider =
    StateProvider<OpenCodeArtifact?>((ref) => null);

/// Resolves the live version of an open artifact from chat state:
/// re-extracts the artifacts of its source message and returns the
/// one at the recorded position, so a panel opened mid-stream follows
/// the code as it arrives. Falls back to the tap-time snapshot when
/// the position no longer resolves (different thread, message
/// replaced, fence not closed yet).
CodeArtifact resolveOpenCodeArtifact(OpenCodeArtifact open, ChatState state) {
  final messageIndex = open.messageIndex;
  if (messageIndex == null) return open.artifact;
  if (open.threadId != state.threadId) return open.artifact;
  if (messageIndex < 0 || messageIndex >= state.messages.length) {
    return open.artifact;
  }
  final artifacts = extractCodeArtifacts(state.messages[messageIndex].content);
  if (open.artifactIndex < 0 || open.artifactIndex >= artifacts.length) {
    return open.artifact;
  }
  return artifacts[open.artifactIndex];
}

/// The open artifact's current content, resolved live from chat
/// state. Null when no panel is open.
final openCodeArtifactLiveProvider = Provider<CodeArtifact?>((ref) {
  final open = ref.watch(openCodeArtifactProvider);
  if (open == null) return null;
  final state = ref.watch(chatViewModelProvider);
  return resolveOpenCodeArtifact(open, state);
});

/// All artifacts from the same message as [open] that carry a file
/// name — the sibling files a multi-file React artifact can import
/// (`App.tsx` importing `./Chart` and `./styles.css` from sibling
/// fenced blocks in the same assistant message).
List<CodeArtifact> collectSiblingArtifacts(
  ChatState state,
  OpenCodeArtifact open,
) {
  final messageIndex = open.messageIndex;
  if (messageIndex == null) return const [];
  if (open.threadId != state.threadId) return const [];
  if (messageIndex < 0 || messageIndex >= state.messages.length) {
    return const [];
  }
  return extractCodeArtifacts(state.messages[messageIndex].content)
      .where((a) => a.fileName != null && a.fileName!.isNotEmpty)
      .toList();
}

/// Sibling files for the open artifact, keyed by file name — the
/// map the React document builder consumes. Excludes the open
/// artifact itself.
final openArtifactSiblingFilesProvider = Provider<Map<String, String>>((ref) {
  final open = ref.watch(openCodeArtifactProvider);
  if (open == null) return const {};
  final state = ref.watch(chatViewModelProvider);
  final siblings = collectSiblingArtifacts(state, open);
  return {
    for (final sibling in siblings)
      if (sibling.fileName != open.artifact.fileName)
        sibling.fileName!: sibling.code,
  };
});

/// Languages the client sandbox can actually execute on the user's
/// device (Python via Pyodide, JavaScript in the sandbox frame). Run
/// controls are only shown for these — a Run button for any other
/// language could only ever produce an error. Must stay in step with
/// the dispatch in `runCodeInClientSandbox` (artifact_sandbox_web /
/// artifact_sandbox_stub).
bool isSandboxRunnableLanguage(String language) {
  final lang = language.toLowerCase();
  return lang == 'python' ||
      lang == 'py' ||
      lang == 'javascript' ||
      lang == 'js';
}

/// Normalizes the language tag from a markdown fence into the id the
/// syntax highlighter expects. Single source for the alias table that
/// used to live only inside the markdown code builder.
String normalizeCodeLanguage(String raw) {
  final language = raw.trim().toLowerCase();
  return switch (language) {
    '' || 'text' || 'txt' => 'plaintext',
    'python3' || 'py' => 'python',
    'js' || 'node' => 'javascript',
    'ts' => 'typescript',
    'sh' || 'zsh' => 'bash',
    'c++' || 'cc' => 'cpp',
    'c#' => 'cs',
    'md' => 'markdown',
    _ => language,
  };
}

/// Display name for a normalized language id, e.g. `Python`.
String codeLanguageDisplayName(String normalizedLanguage) {
  return switch (normalizedLanguage) {
    'python' => 'Python',
    'javascript' => 'JavaScript',
    'typescript' => 'TypeScript',
    'dart' => 'Dart',
    'plaintext' => 'Plain text',
    'bash' => 'Bash',
    'cpp' => 'C++',
    'cs' => 'C#',
    'html' => 'HTML',
    'xml' => 'XML',
    'markdown' => 'Markdown',
    'mermaid' => 'Mermaid',
    'svg' => 'SVG',
    'jsx' || 'tsx' => 'React',
    _ => normalizedLanguage.isEmpty
        ? 'Plain text'
        : '${normalizedLanguage[0].toUpperCase()}${normalizedLanguage.substring(1)}',
  };
}

/// Turns a file name into the card title the way Claude does:
/// `hello_world.py` -> `Hello world`, `chat-screen.dart` -> `Chat screen`.
String humanizeFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final words = stem
      .split(RegExp(r'[_\-\s]+'))
      .where((w) => w.isNotEmpty)
      .join(' ')
      .trim();
  if (words.isEmpty) return fileName;
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

/// File extensions we trust when scanning prose for a file name. Keeping
/// this to real code/config extensions avoids treating abbreviations or
/// version numbers (`e.g.`, `v1.2`) as file names.
const Set<String> _knownFileExtensions = {
  'py',
  'dart',
  'js',
  'ts',
  'jsx',
  'tsx',
  'mjs',
  'cjs',
  'java',
  'kt',
  'kts',
  'swift',
  'go',
  'rs',
  'rb',
  'php',
  'c',
  'h',
  'cpp',
  'cc',
  'cxx',
  'hpp',
  'cs',
  'sh',
  'bash',
  'zsh',
  'ps1',
  'bat',
  'json',
  'yaml',
  'yml',
  'toml',
  'xml',
  'html',
  'htm',
  'css',
  'scss',
  'sql',
  'md',
  'svg',
  'mmd',
  'txt',
  'r',
  'pl',
  'lua',
  'ex',
  'exs',
  'hs',
  'scala',
  'groovy',
  'dockerfile',
};

final RegExp _fileNamePattern = RegExp(
  r'([A-Za-z0-9][A-Za-z0-9_\-]*\.([A-Za-z0-9]{1,5}))\b',
);

String? _lastFileNameIn(String text) {
  String? found;
  for (final match in _fileNamePattern.allMatches(text)) {
    final ext = match.group(2)!.toLowerCase();
    if (_knownFileExtensions.contains(ext)) {
      found = match.group(1);
    }
  }
  return found;
}

String? _fileNameInFirstLineComment(String code) {
  final firstLine = code.split('\n').first.trim();
  if (!firstLine.startsWith('#') &&
      !firstLine.startsWith('//') &&
      !firstLine.startsWith('--')) {
    return null;
  }
  return _lastFileNameIn(firstLine);
}

final RegExp _fencedBlockPattern = RegExp(
  r'```([A-Za-z0-9#+._-]*)\s*\n([\s\S]*?)(?:\n```|```)',
);

final RegExp _shellCommandPattern = RegExp(
  r'^(?:\$\s*)?(?:python3?|pip3?)\s+\S+',
);

bool _hasShellExtension(String? fileName) {
  if (fileName == null) return false;
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return false;
  final ext = fileName.substring(dot + 1).toLowerCase();
  return ext == 'sh' || ext == 'bash' || ext == 'zsh';
}

bool _shouldPromoteToArtifact(CodeArtifact artifact) {
  if (artifact.language == 'bash' && !_hasShellExtension(artifact.fileName)) {
    return false;
  }
  if (artifact.language == 'plaintext' &&
      artifact.fileName == null &&
      artifact.lineCount <= 1) {
    return false;
  }
  if (artifact.language == 'python' &&
      artifact.lineCount <= 1 &&
      _shellCommandPattern.hasMatch(artifact.code.trim())) {
    return false;
  }
  return true;
}

CodeArtifact _artifactFromMatch(
  String markdown,
  Match match,
  int proseStart,
) {
  final rawLanguage = match.group(1) ?? '';
  final code = (match.group(2) ?? '').trimRight();
  final prose = markdown.substring(proseStart, match.start);
  final fileName = _lastFileNameIn(prose) ?? _fileNameInFirstLineComment(code);
  return CodeArtifact.fromCode(
    language: rawLanguage,
    code: code,
    fileName: fileName,
  );
}

/// Extracts promotable fenced code blocks in [markdown], in document
/// order, pairing each with the file name the assistant mentioned for it.
///
/// The file name is resolved, in order, from:
/// 1. the last known-extension file name in the prose since the previous
///    block (covers Claude-style `Here's \`hello_world.py\`:`),
/// 2. a file name in a comment on the code's first line,
/// 3. no name — the card falls back to `<Language> code`.
///
/// Shell command blocks, single-line plain-text output blocks, and
/// unclosed fences (a block still streaming in) are left in the rendered
/// prose as inline blocks rather than becoming artifact cards.
List<CodeArtifact> extractCodeArtifacts(String markdown) {
  final artifacts = <CodeArtifact>[];
  var proseStart = 0;
  for (final match in _fencedBlockPattern.allMatches(markdown)) {
    final artifact = _artifactFromMatch(markdown, match, proseStart);
    if (_shouldPromoteToArtifact(artifact)) {
      artifacts.add(artifact);
    }
    proseStart = match.end;
  }
  return artifacts;
}

/// Returns [markdown] with every promoted fenced code block removed, so
/// the prose renders on its own and the blocks can be presented as
/// artifact cards collected at the end of the message, the way Claude
/// shows created files. Uses the same promotion rules as
/// [extractCodeArtifacts], so the removed blocks and the extracted
/// artifacts always agree. Non-promoted blocks and unclosed fences are
/// left in place (see [extractCodeArtifacts]).
String stripCodeArtifacts(String markdown) {
  final buffer = StringBuffer();
  var cursor = 0;
  for (final match in _fencedBlockPattern.allMatches(markdown)) {
    buffer.write(markdown.substring(cursor, match.start));
    final artifact = _artifactFromMatch(markdown, match, cursor);
    if (!_shouldPromoteToArtifact(artifact)) {
      buffer.write(match.group(0));
    }
    cursor = match.end;
  }
  buffer.write(markdown.substring(cursor));
  return buffer.toString().trim();
}
