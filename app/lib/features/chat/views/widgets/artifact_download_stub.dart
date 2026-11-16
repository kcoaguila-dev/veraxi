import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Saves [content] as [fileName] on device: the system Downloads
/// directory when the platform exposes one, the app documents
/// directory otherwise. Returns the full path the file was written
/// to so the UI can tell the user where it went.
Future<String?> downloadArtifactFile({
  required String fileName,
  required String content,
}) async {
  final downloads = await getDownloadsDirectory();
  final dir = downloads ?? await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, fileName));
  await file.writeAsString(content);
  return file.path;
}
