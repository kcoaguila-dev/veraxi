import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Downloads [content] as [fileName] through the browser: a Blob URL
/// behind a temporary anchor with a `download` attribute — the file
/// lands in the user's downloads folder under its real name.
///
/// Returns null on success (the browser owns the rest) — the native
/// implementation returns the saved path instead.
Future<String?> downloadArtifactFile({
  required String fileName,
  required String content,
}) async {
  final bytes = utf8.encode(content);
  final blob = html.Blob([bytes], 'text/plain;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    final anchor = html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    html.Url.revokeObjectUrl(url);
  }
  return null;
}
