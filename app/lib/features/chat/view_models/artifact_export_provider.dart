import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/artifact_export_repository.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

/// The document formats the backend's artifact export produces.
enum ArtifactExportFormat {
  pdf,
  docx,
  xlsx,
  pptx;

  /// Menu label, e.g. `Word` for the `.docx` export.
  String get label => switch (this) {
        ArtifactExportFormat.pdf => 'PDF',
        ArtifactExportFormat.docx => 'Word',
        ArtifactExportFormat.xlsx => 'Excel',
        ArtifactExportFormat.pptx => 'PowerPoint',
      };

  /// File extension of the exported document (matches [name]).
  String get fileExtension => name;

  String get mimeType => switch (this) {
        ArtifactExportFormat.pdf => 'application/pdf',
        ArtifactExportFormat.docx =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ArtifactExportFormat.xlsx =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ArtifactExportFormat.pptx =>
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      };
}

/// A finished export: the bytes plus everything the download helper
/// needs. The panel (views/) performs the actual download, since the
/// platform download helpers live in the views layer.
class ExportedArtifact {
  final String fileName;
  final Uint8List bytes;
  final String mimeType;

  const ExportedArtifact({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
  });
}

/// The `content_type` the backend should parse this artifact as.
///
/// Markdown, HTML, CSV, and JSON artifacts keep their own type.
/// Plain code has no document structure of its own, so it exports as
/// Markdown wrapping the code in a fenced block (see
/// [artifactExportContent]) — PDF/Word then render it as a code
/// listing, and the other formats carry it as text.
String artifactExportContentType(CodeArtifact artifact) {
  final ext = artifact.fileExtension;
  if (artifact.previewKind == CodePreviewKind.markdown ||
      artifact.language == 'markdown') {
    return 'markdown';
  }
  if (artifact.previewKind == CodePreviewKind.html ||
      artifact.language == 'html') {
    return 'html';
  }
  if (artifact.language == 'csv' || ext == 'csv') return 'csv';
  if (artifact.language == 'json' || ext == 'json') return 'json';
  return 'code';
}

/// The content to send for [artifact]: its code verbatim, except
/// plain code, which is wrapped in a Markdown fenced block so the
/// exporters treat it as a code listing (see
/// [artifactExportContentType]).
String artifactExportContent(CodeArtifact artifact) {
  if (artifactExportContentType(artifact) == 'code') {
    return '```${artifact.language}\n${artifact.code}\n```';
  }
  return artifact.code;
}

/// Whether the Export menu applies to this artifact at all: document
/// shaped artifacts (Markdown / HTML), data artifacts (CSV / JSON),
/// and plain code. Renderable non-document artifacts (SVG, Mermaid,
/// React) are excluded — exporting their source as a document would
/// not be the document the user is looking at.
bool artifactCanExport(CodeArtifact artifact) {
  return artifact.previewKind == CodePreviewKind.markdown ||
      artifact.previewKind == CodePreviewKind.html ||
      artifact.previewKind == CodePreviewKind.none;
}

/// The file name an export downloads under: the artifact's own
/// download name with its extension replaced by the format's.
String artifactExportFileName(
  CodeArtifact artifact,
  ArtifactExportFormat format,
) {
  final base = artifact.downloadFileName;
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  return '$stem.${format.fileExtension}';
}

/// Export state for the artifact panel's Export menu. Scoped to the
/// panel session (autoDispose), like the publish state.
class ArtifactExportState {
  final bool isExporting;
  final ArtifactExportFormat? activeFormat;
  final String? error;

  const ArtifactExportState({
    this.isExporting = false,
    this.activeFormat,
    this.error,
  });
}

class ArtifactExportController extends StateNotifier<ArtifactExportState> {
  ArtifactExportController(this._repository)
      : super(const ArtifactExportState());

  final ArtifactExportRepository _repository;

  /// Exports [artifact] (its current code) as [format]. Returns the
  /// finished document for the caller to download, or null when the
  /// export failed — the reason is then in [ArtifactExportState.error].
  Future<ExportedArtifact?> exportArtifact(
    CodeArtifact artifact,
    ArtifactExportFormat format,
  ) async {
    state = ArtifactExportState(isExporting: true, activeFormat: format);
    try {
      // Plain code travels as Markdown (its content is already the
      // fenced-block rendering from artifactExportContent).
      final rawType = artifactExportContentType(artifact);
      final bytes = await _repository.exportArtifact(
        format: format.name,
        title: artifact.title,
        content: artifactExportContent(artifact),
        contentType: rawType == 'code' ? 'markdown' : rawType,
      );
      state = const ArtifactExportState();
      return ExportedArtifact(
        fileName: artifactExportFileName(artifact, format),
        bytes: bytes,
        mimeType: format.mimeType,
      );
    } catch (e) {
      state = ArtifactExportState(error: _exportErrorMessage(e));
      return null;
    }
  }

  /// The backend's failures arrive as `Exception('Server error: N')`
  /// from ApiClient; translate the ones a user can act on.
  String _exportErrorMessage(Object error) {
    final text = error.toString();
    if (text.contains('413')) {
      return 'This artifact is too large to export.';
    }
    if (text.contains('400')) {
      return 'This artifact cannot be exported in that format.';
    }
    return 'Export failed. Please try again.';
  }
}

final artifactExportProvider = StateNotifierProvider.autoDispose<
    ArtifactExportController, ArtifactExportState>((ref) {
  return ArtifactExportController(
    ref.watch(artifactExportRepositoryProvider),
  );
});
