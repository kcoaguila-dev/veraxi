import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

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
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  try {
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = fileName
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    web.URL.revokeObjectURL(url);
  }
  return null;
}

/// Downloads binary [bytes] (an exported PDF / Office document) as
/// [fileName] through the browser, with the same Blob + anchor flow
/// as [downloadArtifactFile] but honoring the document's [mimeType].
///
/// Returns null on success — the native implementation returns the
/// saved path instead.
Future<String?> downloadArtifactBytes({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  try {
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = fileName
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    web.URL.revokeObjectURL(url);
  }
  return null;
}
