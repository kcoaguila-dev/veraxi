import 'package:veraxi_app/features/chat/view_models/token_usage.dart';

/// How automatic compaction behaves when a conversation's context
/// crosses the trigger. User research across Claude Code / Cline /
/// Roo / Cursor is unambiguous on one point: SILENT auto-compact is
/// the hated configuration — summaries users never saw, installed
/// without notice, with no way back. So the default is [ask]:
/// a prompt at a turn boundary that opens the same preview/edit
/// sheet as manual compaction. [auto] runs the same fail-closed
/// pipeline unattended but always leaves a notice and the in-chat
/// compaction divider. [off] never triggers.
enum AutoCompactMode {
  off,
  ask,
  auto;

  /// Storage value used in SharedPreferences.
  String get storageValue => name;

  /// Parse a stored value; anything unrecognised falls back to
  /// [ask] rather than failing.
  static AutoCompactMode fromStorage(String? value) {
    for (final mode in AutoCompactMode.values) {
      if (mode.name == value) return mode;
    }
    return AutoCompactMode.ask;
  }
}

/// Fraction of the context window that triggers auto-compact.
/// Products ship 90–100% defaults; users who can choose set
/// 50–85%, and ~95% is treated as an emergency brake, not a
/// trigger. 80% matches Copilot's background-compaction point.
const double autoCompactTriggerFraction = 0.80;

/// When the window is unknown (on-device threads with estimated
/// counts), the trigger is an absolute floor instead — the same
/// 20k floor that gates the manual Compact button, so auto never
/// fires on threads manual compaction would refuse as too small
/// to bother with.
const int autoCompactEstimatedFloor = 20000;

/// How far past a "Not now" the context must grow before asking
/// again — enough to not nag every turn, close enough to still
/// catch a growing thread before the emergency zone.
const double autoCompactRearmDelta = 0.10;

/// Normalised fullness of a thread: the unclamped context ratio when
/// the window is known (so re-arm growth past 100% stays measurable),
/// otherwise estimated tokens scaled by the floor (20k tokens = 1.0).
/// Null when there is nothing to judge.
double? autoCompactLevel(TokenUsageSummary summary) {
  final used = summary.contextTokens;
  if (used == null) return null;
  final window = summary.contextWindowTokens;
  if (window != null && window > 0) {
    return used / window;
  }
  return used / autoCompactEstimatedFloor;
}

/// Whether [summary] is past the trigger: ≥80% of a known window,
/// or at/over the absolute floor when the window is unknown.
bool autoCompactDue(TokenUsageSummary summary) {
  final level = autoCompactLevel(summary);
  if (level == null) return false;
  if (summary.contextFraction != null) {
    return level >= autoCompactTriggerFraction;
  }
  return level >= 1.0;
}

/// Per-thread prompt gate: remembers where the user said "Not
/// now" so Ask mode re-arms only after the context grows by
/// [autoCompactRearmDelta] past that point, instead of asking
/// again after every response.
class AutoCompactGate {
  double? _skippedLevel;

  /// True when a prompt (Ask) or run (Auto) should fire now.
  bool shouldFire(TokenUsageSummary summary) {
    if (!autoCompactDue(summary)) return false;
    final level = autoCompactLevel(summary)!;
    final skipped = _skippedLevel;
    if (skipped != null && level < skipped + autoCompactRearmDelta) {
      return false;
    }
    return true;
  }

  /// Record a "Not now" at the current fullness.
  void skip(TokenUsageSummary summary) {
    _skippedLevel = autoCompactLevel(summary);
  }

  /// Forget any skip (thread switch, or a compaction just ran).
  void reset() {
    _skippedLevel = null;
  }
}
