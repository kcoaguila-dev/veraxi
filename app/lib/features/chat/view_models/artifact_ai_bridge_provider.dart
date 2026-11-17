import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/features/chat/data/artifact_ai_repository.dart';

export 'package:veraxi_app/features/chat/data/artifact_ai_repository.dart'
    show ArtifactAiRepository;

/// Prompt/system caps for the in-artifact AI bridge, mirroring the
/// backend's MAX_COMPLETE_PROMPT_CHARS / MAX_COMPLETE_SYSTEM_CHARS
/// (backend/routes/artifacts.py) so an oversize call fails here
/// with a clear error instead of a round-trip 413.
const int maxArtifactAiPromptChars = 16000;
const int maxArtifactAiSystemChars = 16000;
const int maxArtifactAiTokens = 2048;

/// Client-side abuse guard for the bridge: at most this many
/// completions in flight at once and per rolling minute, per app.
/// The backend enforces its own per-tenant rate limit as well;
/// this keeps a misbehaving artifact from queueing unbounded
/// calls behind it.
const int maxArtifactAiInFlight = 4;
const int maxArtifactAiPerMinute = 20;

/// Resolves the model an artifact completion should use when the
/// frame did not name one: the model the user has selected for
/// chat. The selection lives in ChatScreen's widget state and is
/// persisted under the `selected_model` SharedPreferences key
/// (chat_view_model reads SharedPreferences the same way); the
/// placeholder values mean "no selection" and resolve to null,
/// which lets the backend use its configured default model.
Future<String?> resolveSelectedChatModel() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('selected_model');
    if (saved == null || saved.isEmpty || saved == 'Select a model') {
      return null;
    }
    return saved;
  } catch (_) {
    return null;
  }
}

/// A validated AI bridge request from an artifact frame.
class ArtifactAiRequest {
  final String requestId;
  final String prompt;
  final String? system;
  final String? model;
  final int? maxTokens;

  const ArtifactAiRequest({
    required this.requestId,
    required this.prompt,
    this.system,
    this.model,
    this.maxTokens,
  });
}

/// Parses and validates a raw bridge message (a JSON string or a
/// decoded map) from an artifact frame. Returns null — and the
/// caller replies with an error — for anything malformed: wrong
/// type tag, missing/empty requestId, missing/empty/oversize
/// prompt, or wrongly typed options. Host-side validation is the
/// security boundary here: the frame is untrusted.
ArtifactAiRequest? parseArtifactAiMessage(dynamic raw) {
  dynamic decoded = raw;
  if (raw is String) {
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  if (decoded is! Map) return null;
  if (decoded['type'] != 'veraxi_complete') return null;
  final requestId = decoded['requestId'];
  if (requestId is! String || requestId.isEmpty) return null;
  final prompt = decoded['prompt'];
  if (prompt is! String || prompt.trim().isEmpty) return null;
  if (prompt.length > maxArtifactAiPromptChars) return null;
  final system = decoded['system'];
  if (system != null) {
    if (system is! String) return null;
    if (system.length > maxArtifactAiSystemChars) return null;
  }
  final model = decoded['model'];
  if (model != null && model is! String) return null;
  final maxTokens = decoded['maxTokens'];
  if (maxTokens != null) {
    if (maxTokens is! int) return null;
    if (maxTokens < 1 || maxTokens > maxArtifactAiTokens) return null;
  }
  return ArtifactAiRequest(
    requestId: requestId,
    prompt: prompt,
    system: system as String?,
    model: model as String?,
    maxTokens: maxTokens as int?,
  );
}

Map<String, dynamic> _reply(
  String requestId, {
  required bool ok,
  String? text,
  String? error,
}) =>
    {
      'type': 'veraxi_complete_reply',
      'requestId': requestId,
      'ok': ok,
      'text': text,
      'error': error,
    };

/// Mediates AI requests from artifact preview frames to the
/// repository, shaping every reply as
/// `{type: 'veraxi_complete_reply', requestId, ok, text, error}`.
class ArtifactAiBridge {
  ArtifactAiBridge({
    required this.repository,
    Future<String?> Function()? modelResolver,
    DateTime Function()? now,
  })  : _modelResolver = modelResolver ?? resolveSelectedChatModel,
        _now = now ?? DateTime.now;

  final ArtifactAiRepository repository;
  final Future<String?> Function() _modelResolver;
  final DateTime Function() _now;

  int _inFlight = 0;
  final List<DateTime> _callTimes = [];

  bool get _overLimit {
    final cutoff = _now().subtract(const Duration(minutes: 1));
    _callTimes.removeWhere((t) => t.isBefore(cutoff));
    return _inFlight >= maxArtifactAiInFlight ||
        _callTimes.length >= maxArtifactAiPerMinute;
  }

  /// Handles one raw bridge message and returns the reply map to
  /// send back into the frame. Never throws: malformed messages,
  /// guard rejections, and backend failures all come back as
  /// `ok: false` replies.
  Future<Map<String, dynamic>> handle(dynamic raw) async {
    final request = parseArtifactAiMessage(raw);
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
      return _reply(requestId, ok: false, error: 'invalid AI request');
    }
    if (_overLimit) {
      return _reply(
        request.requestId,
        ok: false,
        error: 'AI rate limit reached in this preview; try again shortly',
      );
    }
    _inFlight++;
    _callTimes.add(_now());
    try {
      final text = await repository.complete(
        prompt: request.prompt,
        system: request.system,
        model: request.model ?? await _modelResolver(),
        maxTokens: request.maxTokens,
      );
      return _reply(request.requestId, ok: true, text: text);
    } catch (e) {
      return _reply(request.requestId, ok: false, error: '$e');
    } finally {
      _inFlight--;
    }
  }
}

/// One shared bridge for the whole app, so the in-flight and
/// per-minute guards apply across every artifact preview.
final artifactAiBridgeProvider = Provider<ArtifactAiBridge>((ref) {
  return ArtifactAiBridge(
    repository: ref.watch(artifactAiRepositoryProvider),
  );
});
