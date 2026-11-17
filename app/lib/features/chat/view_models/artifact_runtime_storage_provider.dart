import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/artifact_runtime_storage_repository.dart';

export 'package:veraxi_app/features/chat/data/artifact_runtime_storage_repository.dart'
    show
        ArtifactRuntimeStorageRepository,
        ArtifactStorageLimitException,
        maxStorageKeysPerScope,
        maxStorageScopeChars,
        maxStorageValueChars;

/// The storage scope id for a draft artifact, in the same
/// coordinate shape the backend keys draft scopes by. Null when the
/// artifact has no stable message coordinates.
String? artifactStorageScopeId({
  required String? threadId,
  required int? messageIndex,
  required int artifactIndex,
}) {
  if (messageIndex == null) return null;
  return '${threadId ?? 'local'}:$messageIndex:$artifactIndex';
}

/// The storage scope id for a published artifact.
String artifactPublishedStorageScopeId(String artifactId) => 'pub:$artifactId';

/// A validated storage bridge request from an artifact frame.
class ArtifactStorageRequest {
  final String requestId;
  final String op;
  final String? key;
  final String? value;

  const ArtifactStorageRequest({
    required this.requestId,
    required this.op,
    this.key,
    this.value,
  });
}

/// Parses and validates a raw bridge message (a JSON string or a
/// decoded map) from an artifact frame. Returns null — and the
/// caller replies with an error — for anything malformed: wrong
/// type tag, missing/empty requestId, unknown op, or wrongly typed
/// key/value. Host-side validation is the security boundary here:
/// the frame is untrusted.
ArtifactStorageRequest? parseArtifactStorageMessage(dynamic raw) {
  dynamic decoded = raw;
  if (raw is String) {
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  if (decoded is! Map) return null;
  if (decoded['type'] != 'veraxi_storage') return null;
  final requestId = decoded['requestId'];
  if (requestId is! String || requestId.isEmpty) return null;
  final op = decoded['op'];
  if (op is! String || !const {'get', 'set', 'delete', 'list'}.contains(op)) {
    return null;
  }
  final key = decoded['key'];
  final value = decoded['value'];
  if (op == 'get' || op == 'delete') {
    if (key is! String || key.isEmpty) return null;
  }
  if (op == 'set') {
    if (key is! String || key.isEmpty) return null;
    if (value is! String) return null;
    if (value.length > maxStorageValueChars) return null;
  }
  if (op == 'list' && key != null && key is! String) return null;
  return ArtifactStorageRequest(
    requestId: requestId,
    op: op,
    key: key as String?,
    value: value as String?,
  );
}

Map<String, dynamic> _reply(
  String requestId, {
  required bool ok,
  dynamic data,
  String? error,
}) =>
    {
      'type': 'veraxi_storage_reply',
      'requestId': requestId,
      'ok': ok,
      'data': data,
      'error': error,
    };

/// Mediates storage requests from one artifact scope's preview
/// frame to the repository, shaping every reply as
/// `{type: 'veraxi_storage_reply', requestId, ok, data, error}`.
class ArtifactStorageBridge {
  ArtifactStorageBridge({
    required this.repository,
    required this.scopeId,
  });

  final ArtifactRuntimeStorageRepository repository;
  final String scopeId;

  /// Handles one raw bridge message and returns the reply map to
  /// send back into the frame. Never throws: malformed messages and
  /// limit violations come back as `ok: false` replies.
  Future<Map<String, dynamic>> handle(dynamic raw) async {
    final request = parseArtifactStorageMessage(raw);
    if (request == null) {
      // Best-effort requestId recovery for the error reply.
      var requestId = '';
      try {
        dynamic decoded = raw;
        if (raw is String) decoded = jsonDecode(raw);
        if (decoded is Map && decoded['requestId'] is String) {
          requestId = decoded['requestId'] as String;
        }
      } catch (_) {}
      return _reply(requestId, ok: false, error: 'invalid storage request');
    }
    try {
      switch (request.op) {
        case 'get':
          final value = await repository.get(scopeId, request.key!);
          return _reply(request.requestId, ok: true, data: value);
        case 'set':
          await repository.set(scopeId, request.key!, request.value!);
          return _reply(request.requestId, ok: true);
        case 'delete':
          await repository.delete(scopeId, request.key!);
          return _reply(request.requestId, ok: true);
        case 'list':
          final keys =
              await repository.list(scopeId, prefix: request.key ?? '');
          return _reply(request.requestId, ok: true, data: keys);
        default:
          return _reply(request.requestId,
              ok: false, error: 'unknown op ${request.op}');
      }
    } on ArtifactStorageLimitException catch (e) {
      return _reply(request.requestId, ok: false, error: e.message);
    } catch (e) {
      return _reply(request.requestId, ok: false, error: '$e');
    }
  }
}

/// One bridge per storage scope, shared by the scope's previews.
final artifactStorageBridgeProvider =
    Provider.family<ArtifactStorageBridge, String>((ref, scopeId) {
  return ArtifactStorageBridge(
    repository: ref.watch(artifactRuntimeStorageRepositoryProvider),
    scopeId: scopeId,
  );
});
