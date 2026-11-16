import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';

/// Syntax-highlighting modes for the artifact panel's code editor
/// (re_editor / re_highlight), keyed by the normalized language ids
/// from `normalizeCodeLanguage`. Languages without a mode here fall
/// back to plain text in the editor — the editor still works, it just
/// doesn't colorize. The read-only card/panel highlighting elsewhere
/// (flutter_highlighter) has its own, wider table; this one only
/// covers the languages the editor is likely to meet.
final Map<String, CodeHighlightThemeMode> artifactEditorLanguageModes = {
  'python': CodeHighlightThemeMode(mode: langPython),
  'javascript': CodeHighlightThemeMode(mode: langJavascript),
  'typescript': CodeHighlightThemeMode(mode: langTypescript),
  'jsx': CodeHighlightThemeMode(mode: langJavascript),
  'tsx': CodeHighlightThemeMode(mode: langTypescript),
  'dart': CodeHighlightThemeMode(mode: langDart),
  'java': CodeHighlightThemeMode(mode: langJava),
  'kotlin': CodeHighlightThemeMode(mode: langKotlin),
  'swift': CodeHighlightThemeMode(mode: langSwift),
  'go': CodeHighlightThemeMode(mode: langGo),
  'rust': CodeHighlightThemeMode(mode: langRust),
  'cpp': CodeHighlightThemeMode(mode: langCpp),
  'c': CodeHighlightThemeMode(mode: langCpp),
  'cs': CodeHighlightThemeMode(mode: langCsharp),
  'php': CodeHighlightThemeMode(mode: langPhp),
  'ruby': CodeHighlightThemeMode(mode: langRuby),
  'bash': CodeHighlightThemeMode(mode: langBash),
  'json': CodeHighlightThemeMode(mode: langJson),
  'xml': CodeHighlightThemeMode(mode: langXml),
  'html': CodeHighlightThemeMode(mode: langXml),
  'svg': CodeHighlightThemeMode(mode: langXml),
  'css': CodeHighlightThemeMode(mode: langCss),
  'scss': CodeHighlightThemeMode(mode: langScss),
  'sql': CodeHighlightThemeMode(mode: langSql),
  'yaml': CodeHighlightThemeMode(mode: langYaml),
  'toml': CodeHighlightThemeMode(mode: langIni),
  'markdown': CodeHighlightThemeMode(mode: langMarkdown),
  'lua': CodeHighlightThemeMode(mode: langLua),
  'plaintext': CodeHighlightThemeMode(mode: langPlaintext),
};

/// The editor highlight theme for [language]: the artifact's language
/// mode (or plain text) over the same Atom One Dark palette the
/// read-only panel used, so edit and read views look identical.
CodeHighlightTheme artifactEditorTheme(String language) {
  final mode = artifactEditorLanguageModes[language] ??
      artifactEditorLanguageModes['plaintext']!;
  return CodeHighlightTheme(
    languages: {language: mode},
    theme: atomOneDarkTheme,
  );
}
