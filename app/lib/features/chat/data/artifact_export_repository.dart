import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Talks to the backend's artifact export endpoint
/// (`POST /api/artifacts/export`), which deterministically converts
/// artifact content to PDF / DOCX / XLSX / PPTX bytes server-side
/// (no code is executed). Unlike publishing, export is open to guest
/// tenants — it is a pure function of the caller's own content.
class ArtifactExportRepository {
  ArtifactExportRepository(this._apiClient);

  final ApiClient _apiClient;

  /// Exports the artifact and returns the document bytes. [format]
  /// is one of `pdf` / `docx` / `xlsx` / `pptx`; [contentType] tells
  /// the backend how to parse [content] (`markdown`, `html`, `csv`,
  /// or `json`). A structured [spec] (sections / sheets / slides)
  /// may be supplied instead of relying on content parsing.
  /// Throws on any non-200 response (see [ApiClient.postBytes]).
  Future<Uint8List> exportArtifact({
    required String format,
    required String title,
    required String content,
    required String contentType,
    Map<String, dynamic>? spec,
  }) {
    return _apiClient.postBytes('/artifacts/export', body: {
      'format': format,
      'title': title,
      'content': content,
      'content_type': contentType,
      if (spec != null) 'spec': spec,
    });
  }
}

final artifactExportRepositoryProvider =
    Provider<ArtifactExportRepository>((ref) {
  return ArtifactExportRepository(ref.watch(apiClientProvider));
});
