import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_store.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_sync_repository.dart';

export 'package:veraxi_app/features/chat/data/artifact_work_store.dart'
    show ArtifactWorkState, ArtifactWorkStore, artifactWorkKey;

/// The store the artifact panel persists its work to (versions,
/// current version, published link): a local cache synced through
/// the backend, so panel work survives closing the panel and
/// follows the user across devices. Exposed here so views depend
/// on view_models only, per the feature's import direction.
final artifactWorkStoreProvider = Provider<ArtifactWorkStore>((ref) {
  return ArtifactWorkStore(
    sync: ref.watch(artifactWorkSyncRepositoryProvider),
  );
});
