import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_store.dart';

export 'package:veraxi_app/features/chat/data/artifact_work_store.dart'
    show ArtifactWorkState, artifactWorkKey;

/// The local store the artifact panel persists its work to
/// (versions, current version, published link), so panel work
/// survives closing the panel. Exposed here so views depend on
/// view_models only, per the feature's import direction.
final artifactWorkStoreProvider = Provider<ArtifactWorkStore>((ref) {
  return ArtifactWorkStore();
});
