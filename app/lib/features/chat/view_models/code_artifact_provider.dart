import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return CodeArtifact(
      title: fileName != null
          ? humanizeFileName(fileName)
          : '${codeLanguageDisplayName(normalized)} code',
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

/// The code artifact currently open in the right-side panel, or null when
/// the panel is closed. Set by tapping a [CodeArtifact] card in a message;
/// cleared by the panel's close button or when the chat is emptied.
final openCodeArtifactProvider = StateProvider<CodeArtifact?>((ref) => null);

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
    'html' => 'xml',
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
    'xml' => 'HTML',
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

/// Extracts every fenced code block in [markdown], in document order,
/// pairing each with the file name the assistant mentioned for it.
///
/// The file name is resolved, in order, from:
/// 1. the last known-extension file name in the prose since the previous
///    block (covers Claude-style `Here's \`hello_world.py\`:`),
/// 2. a file name in a comment on the code's first line,
/// 3. no name — the card falls back to `<Language> code`.
///
/// Unclosed fences (a block still streaming in) are ignored here; the
/// markdown builder falls back to building an artifact directly for any
/// block this misses, so a card still renders.
List<CodeArtifact> extractCodeArtifacts(String markdown) {
  final artifacts = <CodeArtifact>[];
  var proseStart = 0;
  for (final match in _fencedBlockPattern.allMatches(markdown)) {
    final rawLanguage = match.group(1) ?? '';
    final code = (match.group(2) ?? '').trimRight();
    final prose = markdown.substring(proseStart, match.start);
    final fileName =
        _lastFileNameIn(prose) ?? _fileNameInFirstLineComment(code);
    artifacts.add(CodeArtifact.fromCode(
      language: rawLanguage,
      code: code,
      fileName: fileName,
    ));
    proseStart = match.end;
  }
  return artifacts;
}
