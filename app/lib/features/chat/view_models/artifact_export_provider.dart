import 'dart:convert';
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
      artifact.previewKind == CodePreviewKind.slides ||
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

/// The download file name for an export titled [title] rather than
/// named by a file: the title sanitized the way the backend sanitizes
/// attachment names (`_safe_export_filename`), plus the format's
/// extension.
String titledExportFileName(String title, ArtifactExportFormat format) {
  var stem = title.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  stem = stem.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
  if (stem.length > 80) stem = stem.substring(0, 80);
  stem = stem.replaceAll(RegExp(r'[._]+$'), '');
  return '${stem.isEmpty ? 'artifact' : stem}.${format.fileExtension}';
}

/// A `create_office_artifact` envelope: the fenced ```json block the
/// chat tool returns for a generated document. Alongside the spec
/// payload (`slides` / `sheets` / `sections`) — or a `content` /
/// `content_type` pair for prose documents — it carries the intended
/// `format` and `title`, which a plain JSON artifact cannot otherwise
/// express. The export endpoint accepts the same envelope server-side
/// (see `_unwrap_office_envelope` in the backend's artifacts route).
class OfficeArtifactEnvelope {
  /// The format the tool produced the document for, when declared.
  final String? format;

  /// The document title declared by the tool, when present.
  final String? title;

  /// The spec payload with the envelope keys removed, or null for a
  /// content-driven envelope.
  final Map<String, dynamic>? spec;

  /// The wrapped document body for a content-driven envelope.
  final String? content;

  /// How to parse [content] (`markdown` / `csv` / `html`).
  final String? contentType;

  const OfficeArtifactEnvelope({
    this.format,
    this.title,
    this.spec,
    this.content,
    this.contentType,
  });
}

/// Parses [artifact] as a [OfficeArtifactEnvelope], or returns null
/// when it is not one: non-JSON artifacts, invalid JSON, and JSON
/// objects with neither a spec payload nor a content body are all
/// plain JSON artifacts and export as before.
OfficeArtifactEnvelope? parseOfficeArtifactEnvelope(CodeArtifact artifact) {
  if (artifact.language != 'json' && artifact.fileExtension != 'json') {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(artifact.code);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final spec = <String, dynamic>{
    for (final entry in decoded.entries)
      if (entry.key != 'format' &&
          entry.key != 'title' &&
          entry.key != 'content' &&
          entry.key != 'content_type')
        entry.key: entry.value,
  };
  final hasSpecPayload = spec.containsKey('slides') ||
      spec.containsKey('sheets') ||
      spec.containsKey('sections');
  final content = decoded['content'];
  if (!hasSpecPayload && content is! String) return null;
  final format = decoded['format'];
  final title = decoded['title'];
  final contentType = decoded['content_type'];
  return OfficeArtifactEnvelope(
    format: format is String ? format : null,
    title: title is String && title.isNotEmpty ? title : null,
    spec: hasSpecPayload ? spec : null,
    content: content is String ? content : null,
    contentType: contentType is String ? contentType : null,
  );
}

/// The export formats valid for [artifact].
///
/// When [artifact] is a `create_office_artifact` envelope with a known
/// declared `format` (or a spec payload tied to a specific format),
/// only the matching format is returned so the Export menu never offers
/// an incompatible format that would fail with HTTP 400. All other
/// exportable artifacts offer every [ArtifactExportFormat].
List<ArtifactExportFormat> availableExportFormats(CodeArtifact artifact) {
  final envelope = parseOfficeArtifactEnvelope(artifact);
  if (envelope == null) return ArtifactExportFormat.values;
  final declared = envelope.format?.toLowerCase();
  if (declared != null) {
    for (final fmt in ArtifactExportFormat.values) {
      if (fmt.fileExtension == declared) return [fmt];
    }
  }
  final spec = envelope.spec;
  if (spec != null) {
    if (spec.containsKey('slides')) return const [ArtifactExportFormat.pptx];
    if (spec.containsKey('sheets')) return const [ArtifactExportFormat.xlsx];
    if (spec.containsKey('sections')) return const [ArtifactExportFormat.docx];
  }
  return ArtifactExportFormat.values;
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
      // A create_office_artifact envelope carries its own title and
      // either a spec payload or a wrapped content body; export that
      // directly instead of treating the JSON as opaque content.
      final envelope = parseOfficeArtifactEnvelope(artifact);
      final title = envelope?.title ?? artifact.title;
      final Uint8List bytes;
      if (envelope?.spec != null) {
        bytes = await _repository.exportArtifact(
          format: format.name,
          title: title,
          content: '',
          contentType: 'json',
          spec: envelope!.spec,
        );
      } else if (envelope?.content != null) {
        bytes = await _repository.exportArtifact(
          format: format.name,
          title: title,
          content: envelope!.content!,
          contentType: envelope.contentType ?? 'markdown',
        );
      } else {
        // Plain code travels as Markdown (its content is already the
        // fenced-block rendering from artifactExportContent).
        final rawType = artifactExportContentType(artifact);
        bytes = await _repository.exportArtifact(
          format: format.name,
          title: title,
          content: artifactExportContent(artifact),
          contentType: rawType == 'code' ? 'markdown' : rawType,
        );
      }
      state = const ArtifactExportState();
      return ExportedArtifact(
        fileName: envelope?.title != null
            ? titledExportFileName(title, format)
            : artifactExportFileName(artifact, format),
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
