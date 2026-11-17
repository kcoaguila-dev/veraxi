import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

/// A pending write-action confirmation extracted from a chat message.
///
/// The backend dispatch gate returns a `tool_confirmation_required`
/// payload instead of executing mutating external tools
/// (github_create_issue, github_comment_pr, non-GET OpenAPI calls).
class ToolConfirmationRequest {
  final String toolName;
  final Map<String, dynamic> args;
  final String? message;

  const ToolConfirmationRequest({
    required this.toolName,
    required this.args,
    this.message,
  });
}

/// Extract a [ToolConfirmationRequest] from message text, or null.
///
/// Accepts both the JSON form (`{"tool_confirmation_required": {...}}`)
/// and the Python-repr form the telemetry context uses (single quotes),
/// since either may surface in the assistant's reply text.
ToolConfirmationRequest? extractToolConfirmation(String content) {
  final marker = content.indexOf('tool_confirmation_required');
  if (marker < 0) return null;
  // Find the enclosing JSON object: the first '{' before the marker
  // whose balanced object parses and contains the marker key.
  var searchFrom = 0;
  while (true) {
    final open = content.indexOf('{', searchFrom);
    if (open < 0 || open > marker) return null;
    final objectText = _balancedObject(content, open);
    if (objectText == null) return null;
    final parsed = _tryParseObject(objectText);
    if (parsed != null && parsed.containsKey('tool_confirmation_required')) {
      final payload = parsed['tool_confirmation_required'];
      if (payload is Map) {
        final map = Map<String, dynamic>.from(payload);
        final toolName = map['tool_name'] as String?;
        if (toolName == null || toolName.isEmpty) return null;
        return ToolConfirmationRequest(
          toolName: toolName,
          args: Map<String, dynamic>.from(map['args'] as Map? ?? {}),
          message: map['message'] as String?,
        );
      }
      return null;
    }
    searchFrom = open + 1;
  }
}

String? _balancedObject(String text, int openIndex) {
  var depth = 0;
  var inString = false;
  var stringChar = '';
  var escaped = false;
  for (var i = openIndex; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == stringChar) {
        inString = false;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      inString = true;
      stringChar = ch;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return text.substring(openIndex, i + 1);
    }
  }
  return null;
}

Map<String, dynamic>? _tryParseObject(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // Fall through to the repr-tolerant parse below.
  }
  // Python dict repr: single-quoted strings, True/False/None literals.
  try {
    final normalized = text
        .replaceAll("'", '"')
        .replaceAll(': True', ': true')
        .replaceAll(': False', ': false')
        .replaceAll(': None', ': null');
    final decoded = jsonDecode(normalized);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    return null;
  }
  return null;
}

/// Sends the user's decision for a gated tool call to the backend.
final toolConfirmationServiceProvider =
    Provider<ToolConfirmationService>((ref) {
  final repository = ref.watch(chatRepositoryProvider);
  return ToolConfirmationService(repository);
});

class ToolConfirmationService {
  final IChatRepository _repository;

  ToolConfirmationService(this._repository);

  /// Returns the backend result (`status`: executed/rejected, plus the
  /// tool result text when executed).
  Future<Map<String, dynamic>> decide(
    ToolConfirmationRequest request, {
    required bool approve,
  }) async {
    try {
      return await _repository.confirmToolCall(
        toolName: request.toolName,
        args: request.args,
        approve: approve,
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }
}
