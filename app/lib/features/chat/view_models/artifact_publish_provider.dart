import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/artifact_publish_repository.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

/// Publish state for the artifact panel's Share action. Scoped to
/// the panel session (autoDispose): closing the panel forgets the
/// link locally — the published page itself lives on the backend
/// until it is unpublished.
class ArtifactPublishState {
  final bool isPublishing;
  final String? publishedId;
  final String? publishedUrl;

  /// The code as it was when published. The panel compares it with
  /// the current version to know the link is stale.
  final String? publishedCode;
  final String? error;

  const ArtifactPublishState({
    this.isPublishing = false,
    this.publishedId,
    this.publishedUrl,
    this.publishedCode,
    this.error,
  });

  /// True when a link exists but the code has moved on since it was
  /// published — sharing again updates the page in place.
  bool isStale(String currentCode) =>
      publishedUrl != null && publishedCode != currentCode;

  ArtifactPublishState copyWith({
    bool? isPublishing,
    String? error,
    bool clearError = false,
  }) {
    return ArtifactPublishState(
      isPublishing: isPublishing ?? this.isPublishing,
      publishedId: publishedId,
      publishedUrl: publishedUrl,
      publishedCode: publishedCode,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ArtifactPublishController extends StateNotifier<ArtifactPublishState> {
  ArtifactPublishController(this._repository)
      : super(const ArtifactPublishState());

  final ArtifactPublishRepository _repository;

  /// Publishes the artifact's current code (republishing under the
  /// same id when a link already exists, so the URL is stable).
  Future<void> publish(CodeArtifact artifact, String currentCode) async {
    state = state.copyWith(isPublishing: true, clearError: true);
    try {
      final published = await _repository.publish(
        title: artifact.title,
        fileName: artifact.fileName,
        language: artifact.language,
        code: currentCode,
        // The backend's kind vocabulary has no "none": plain code
        // publishes as "code".
        kind: artifact.previewKind == CodePreviewKind.none
            ? 'code'
            : artifact.previewKind.name,
        existingId: state.publishedId,
      );
      state = ArtifactPublishState(
        publishedId: published.id,
        publishedUrl: published.url,
        publishedCode: currentCode,
      );
    } catch (e) {
      state = state.copyWith(
        isPublishing: false,
        error: _publishErrorMessage(e),
      );
    }
  }

  /// Restores a link published in an earlier panel session (the
  /// panel loads it from the local work store) without calling the
  /// backend — the page itself never went away.
  void restore({required String id, required String url, String? code}) {
    state = ArtifactPublishState(
      publishedId: id,
      publishedUrl: url,
      publishedCode: code,
    );
  }

  /// Unpublishes: the public URL stops working and the local link
  /// is forgotten.
  Future<void> unpublish() async {
    final id = state.publishedId;
    if (id == null) return;
    try {
      await _repository.unpublish(id);
      state = const ArtifactPublishState();
    } catch (e) {
      state = state.copyWith(error: _publishErrorMessage(e));
    }
  }

  /// The backend's failures arrive as `Exception('Server error: N')`
  /// from ApiClient; translate the ones a user can act on.
  String _publishErrorMessage(Object error) {
    final text = error.toString();
    if (text.contains('401') || text.contains('403')) {
      return 'Sign in to publish artifacts.';
    }
    return 'Publishing failed. Please try again.';
  }
}

final artifactPublishProvider = StateNotifierProvider.autoDispose<
    ArtifactPublishController, ArtifactPublishState>((ref) {
  return ArtifactPublishController(
    ref.watch(artifactPublishRepositoryProvider),
  );
});
