/// Pure helpers for on-device (local thread) compaction.
///
/// Mirrors the server-side rules in backend/mcp_server/compaction.py:
/// cuts land on user-turn boundaries, compaction must free at least
/// ~10% to be worth it, and the summary message carries the same
/// `compaction` metrics record so the UI renders the same divider.
///
/// Token counts here are ESTIMATES (chars / 4): on-device threads
/// have no provider-reported usage to lean on. They are labelled
/// estimates everywhere they surface.
library;

const String kSummaryPrefix =
    '[Conversation summary — earlier messages were compacted]';
const String kClearedToolPlaceholder = '[Tool result cleared to free context]';
const double kMinProgressFraction = 0.10;

int estimateTokens(String text) => (text.length / 4).ceil();

int estimateHistoryTokens(List<Map<String, dynamic>> messages) {
  var total = 0;
  for (final message in messages) {
    total += estimateTokens(message['content'] as String? ?? '');
    final toolEvents = message['toolEvents'];
    if (toolEvents is List) {
      for (final event in toolEvents) {
        if (event is Map && event['result'] is String) {
          total += estimateTokens(event['result'] as String);
        }
      }
    }
  }
  return total;
}

/// Split history into (prefix, recent): recent = the last
/// [keepRecentTurns] user turns, starting exactly at a 'user'
/// message so a turn is never split.
(List<Map<String, dynamic>>, List<Map<String, dynamic>>) splitLocalHistory(
    List<Map<String, dynamic>> messages, int keepRecentTurns) {
  if (keepRecentTurns <= 0) return (messages, <Map<String, dynamic>>[]);
  final userIndices = <int>[
    for (var i = 0; i < messages.length; i++)
      if (messages[i]['role'] == 'user') i,
  ];
  if (userIndices.length <= keepRecentTurns) {
    return (<Map<String, dynamic>>[], messages);
  }
  final cut = userIndices[userIndices.length - keepRecentTurns];
  return (messages.sublist(0, cut), messages.sublist(cut));
}

/// Throws an Exception with a user-facing message when compaction
/// would free less than the minimum-progress fraction.
void checkLocalMinProgress(int before, int after) {
  if (before <= 0) return;
  final saved = before - after;
  if (saved < kMinProgressFraction * before) {
    throw Exception(
        'Compaction would only free ~$saved of ~$before tokens (<10%) — not worth losing the detail.');
  }
}

String buildLocalSummaryContent(String summary) =>
    '$kSummaryPrefix\n\n${summary.trim()}';

Map<String, dynamic> localCompactionRecord(
        int messagesCompacted, int tokensBefore,
        {bool estimated = true}) =>
    {
      'compaction': {
        'messages_compacted': messagesCompacted,
        'compacted_at': DateTime.now().toUtc().toIso8601String(),
        'tokens_before': tokensBefore,
        'estimated': estimated,
      },
    };

/// The summarization prompt for the on-device model: same structure
/// the server prompt demands (verbatim user constraints first-class).
String buildLocalCompactionPrompt(
    List<Map<String, dynamic>> prefix, String? focus) {
  final transcript = prefix
      .map((m) =>
          '${m['role'] == 'user' ? 'User' : 'Assistant'}: ${m['content'] as String? ?? ''}')
      .join('\n\n');
  final focusLine = (focus != null && focus.isNotEmpty)
      ? '\nFocus instruction from the user: $focus\n'
      : '';
  return '''
Summarize the conversation below so it can continue in a smaller context window. Use EXACTLY these sections:

## Goal
What the user is trying to achieve.

## Decisions
Decisions made, with rationale. Include approaches tried and rejected, and why.

## User constraints & preferences
Every instruction, constraint, or preference the user stated, as a verbatim-style bullet list. Do not drop any.

## Facts & evidence
Key facts established.

## Work completed
What has actually been done (done, not merely planned).

## Open tasks & next steps
What remains, in order.

Be specific (names, numbers, values). Never invent details not in the conversation.$focusLine
Conversation:
$transcript

Summary:''';
}

/// Stage 0 for local threads: tool results live inside assistant
/// messages' toolEvents (there are no tool-role messages on-device).
/// Replace prefix tool-event results with a placeholder. Returns
/// (newMessages, clearedCount). Already-cleared results are skipped.
(List<Map<String, dynamic>>, int) clearLocalToolResults(
    List<Map<String, dynamic>> messages, int keepRecentTurns) {
  final (prefix, recent) = splitLocalHistory(messages, keepRecentTurns);
  var cleared = 0;
  final newPrefix = <Map<String, dynamic>>[];
  for (final message in prefix) {
    final toolEvents = message['toolEvents'];
    if (toolEvents is List && toolEvents.isNotEmpty) {
      var changed = false;
      final newEvents = <dynamic>[];
      for (final event in toolEvents) {
        if (event is Map &&
            event['result'] is String &&
            (event['result'] as String).isNotEmpty &&
            !(event['result'] as String).startsWith(kClearedToolPlaceholder)) {
          final copy = Map<String, dynamic>.from(event);
          copy['result'] =
              '$kClearedToolPlaceholder (originally ~${(event['result'] as String).length} chars)';
          newEvents.add(copy);
          changed = true;
          cleared++;
        } else {
          newEvents.add(event);
        }
      }
      if (changed) {
        newPrefix.add({...message, 'toolEvents': newEvents});
        continue;
      }
    }
    newPrefix.add(message);
  }
  return ([...newPrefix, ...recent], cleared);
}
