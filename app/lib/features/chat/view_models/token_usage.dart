import 'package:veraxi_app/features/chat/view_models/chat_state.dart';

/// How the context-usage indicator is rendered in the chat composer.
///
/// User-selectable (persisted) because the two visible forms serve
/// different readers: the ring is compact and glanceable, the bar is
/// read faster and shows the counts as text. Rivals ship only an
/// on/off toggle (LibreChat `interface.contextUsage`, VS Code's
/// indicator setting); Veraxi lets the user pick the form too.
/// [off] hides the indicator entirely, matching the hide option users
/// asked VS Code for (issue #293578, token-budget anxiety).
enum TokenUsageIndicatorStyle {
  ring,
  bar,
  off;

  /// Storage value used in SharedPreferences.
  String get storageValue => name;

  /// Parse a stored value; anything unrecognised falls back to the
  /// [ring] default rather than failing.
  static TokenUsageIndicatorStyle fromStorage(String? value) {
    for (final style in TokenUsageIndicatorStyle.values) {
      if (style.name == value) return style;
    }
    return TokenUsageIndicatorStyle.ring;
  }
}

/// Aggregated token usage for one conversation, derived purely from the
/// per-message metrics the backend already returns (and persists).
///
/// Semantics follow the context-gauge pattern used by LibreChat and
/// other ChatGPT wrappers:
/// - [contextTokens] is the *latest* assistant response's prompt token
///   count. Every request resends the conversation, so that number is
///   how full the model's context window actually is right now — not a
///   sum, and never a client-side estimate.
/// - The session totals, by contrast, *are* sums across responses:
///   what the conversation has consumed in total.
/// - [contextWindowTokens] comes from the backend (LiteLLM's model
///   map). When it is null the model is unmapped and the UI shows
///   counts only — a percentage is never fabricated.
class TokenUsageSummary {
  final int? contextTokens;
  final int? contextWindowTokens;
  final int? lastPromptTokens;
  final int? lastCompletionTokens;
  final int? lastTotalTokens;
  final double? lastEstimatedCostUsd;
  final int sessionPromptTokens;
  final int sessionCompletionTokens;
  final int sessionTotalTokens;
  final double sessionEstimatedCostUsd;
  final bool hasSessionCost;
  final int responseCount;

  /// Category split of the *latest* request's context, counted
  /// locally by the backend at prompt-build time (system prompts /
  /// tool schemas / tool results incl. retrieved context / dialogue).
  /// All four are null when the backend could not count (older
  /// payloads, counting failure) — the split is explanatory and the
  /// headline totals stay provider-reported.
  final int? contextSystemTokens;
  final int? contextToolsTokens;
  final int? contextToolResultsTokens;
  final int? contextMessagesTokens;

  const TokenUsageSummary({
    required this.contextTokens,
    required this.contextWindowTokens,
    required this.lastPromptTokens,
    required this.lastCompletionTokens,
    required this.lastTotalTokens,
    required this.lastEstimatedCostUsd,
    required this.sessionPromptTokens,
    required this.sessionCompletionTokens,
    required this.sessionTotalTokens,
    required this.sessionEstimatedCostUsd,
    required this.hasSessionCost,
    required this.responseCount,
    this.contextSystemTokens,
    this.contextToolsTokens,
    this.contextToolResultsTokens,
    this.contextMessagesTokens,
  });

  /// Whether the latest response carried a category split.
  bool get hasBreakdown =>
      contextSystemTokens != null &&
      contextToolsTokens != null &&
      contextToolResultsTokens != null &&
      contextMessagesTokens != null;

  /// Sum of the split segments (local counts; may drift slightly
  /// from the provider-reported prompt total — different tokenizers).
  int get breakdownTotal =>
      (contextSystemTokens ?? 0) +
      (contextToolsTokens ?? 0) +
      (contextToolResultsTokens ?? 0) +
      (contextMessagesTokens ?? 0);

  /// Fraction of the context window in use, 0.0–1.0 (clamped), or null
  /// when the window or the latest prompt count is unknown.
  double? get contextFraction {
    final used = contextTokens;
    final window = contextWindowTokens;
    if (used == null || window == null || window <= 0) return null;
    return (used / window).clamp(0.0, 1.0);
  }

  int? get contextTokensRemaining {
    final used = contextTokens;
    final window = contextWindowTokens;
    if (used == null || window == null) return null;
    final remaining = window - used;
    return remaining < 0 ? 0 : remaining;
  }

  bool get hasUsage => responseCount > 0;
}

/// Build a [TokenUsageSummary] from a conversation's messages, or null
/// when no assistant message carries provider-reported usage.
TokenUsageSummary? summarizeTokenUsage(List<ChatMessage> messages) {
  var sessionPrompt = 0;
  var sessionCompletion = 0;
  var sessionTotal = 0;
  var sessionCost = 0.0;
  var hasCost = false;
  var count = 0;

  int? contextTokens;
  int? contextWindow;
  int? lastPrompt;
  int? lastCompletion;
  int? lastTotal;
  double? lastCost;
  int? segSystem;
  int? segTools;
  int? segToolResults;
  int? segMessages;

  for (final message in messages) {
    if (message.isUser) continue;
    final metrics = message.metrics;
    if (metrics == null) continue;
    // Accept the nested `usage` map as well as the flattened keys, the
    // same tolerance ChatMessageMetrics applies to older payloads.
    final usage = metrics['usage'];
    final source = usage is Map ? Map<String, dynamic>.from(usage) : metrics;
    final prompt = _toInt(source['prompt_tokens']);
    final completion = _toInt(source['completion_tokens']);
    final total = _toInt(source['total_tokens']);
    if (prompt == null && completion == null && total == null) continue;

    count++;
    sessionPrompt += prompt ?? 0;
    sessionCompletion += completion ?? 0;
    sessionTotal += total ?? ((prompt ?? 0) + (completion ?? 0));
    final cost = _toDouble(source['estimated_cost_usd']);
    if (cost != null) {
      sessionCost += cost;
      hasCost = true;
    }

    // Messages are chronological, so the last usage-bearing response
    // overwrites these: it is the current context state.
    contextTokens = prompt;
    contextWindow = _toInt(source['context_window_tokens']) ?? contextWindow;
    lastPrompt = prompt;
    lastCompletion = completion;
    lastTotal = total;
    lastCost = cost;
    // Segment counts are flattened at metrics top level by the
    // backend (not inside the nested `usage` map), so read `metrics`.
    segSystem = _toInt(metrics['context_system_tokens']) ?? segSystem;
    segTools = _toInt(metrics['context_tools_tokens']) ?? segTools;
    segToolResults =
        _toInt(metrics['context_tool_results_tokens']) ?? segToolResults;
    segMessages = _toInt(metrics['context_messages_tokens']) ?? segMessages;
  }

  if (count == 0) return null;
  return TokenUsageSummary(
    contextTokens: contextTokens,
    contextWindowTokens: contextWindow,
    lastPromptTokens: lastPrompt,
    lastCompletionTokens: lastCompletion,
    lastTotalTokens: lastTotal,
    lastEstimatedCostUsd: lastCost,
    sessionPromptTokens: sessionPrompt,
    sessionCompletionTokens: sessionCompletion,
    sessionTotalTokens: sessionTotal,
    sessionEstimatedCostUsd: sessionCost,
    hasSessionCost: hasCost,
    responseCount: count,
    contextSystemTokens: segSystem,
    contextToolsTokens: segTools,
    contextToolResultsTokens: segToolResults,
    contextMessagesTokens: segMessages,
  );
}

/// Compact token count for the ring's centre label: `812`, `41k`,
/// `1.2M`. Exact counts live in the breakdown sheet.
String formatTokenCount(int value) {
  if (value < 1000) return '$value';
  if (value < 10000) return '${(value / 1000).toStringAsFixed(1)}k';
  if (value < 1000000) return '${(value / 1000).round()}k';
  return '${(value / 1000000).toStringAsFixed(1)}M';
}

/// Full token count with thousands separators for the breakdown sheet.
String formatTokenCountFull(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

int? _toInt(dynamic value) {
  if (value is num) return value.toInt();
  return null;
}

double? _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return null;
}
