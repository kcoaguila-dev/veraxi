import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';

/// One agent skill as listed by the Code composer's `$` picker.
///
/// Mirrors the records `AgentSkillsView` (Knowledge Hub) manages in
/// the `tool_settings['skills']` SharedPreferences document — that
/// view owns the editing UI; this is the read side for the composer.
class AgentSkillEntry {
  final String id;
  final String name;
  final String description;
  final bool enabled;

  const AgentSkillEntry({
    required this.id,
    required this.name,
    this.description = '',
    this.enabled = true,
  });
}

/// Enabled agent skills for the `$` autocomplete, read from the same
/// `tool_settings` document the chat send path forwards to the
/// backend (the data source behind `AgentSkillsView`).
final agentSkillsProvider =
    FutureProvider.autoDispose<List<AgentSkillEntry>>((ref) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    if ((settingsJson ?? '').isEmpty) return const [];
    final settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
    final raw = settings['skills'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => AgentSkillEntry(
              id: e['id']?.toString() ?? '',
              name: e['name']?.toString() ?? '',
              description: e['description']?.toString() ?? '',
              enabled: e['enabled'] as bool? ?? true,
            ))
        .where((skill) => skill.enabled && skill.name.isNotEmpty)
        .toList();
  } catch (e, st) {
    await Sentry.captureException(e, stackTrace: st);
    return const [];
  }
});

/// Builds the Phase 1 Code Mode scope stamped onto a POST /api/chat
/// request (top-level `ChatRequest` fields, not `tool_settings`).
///
/// [repoKey] is the primary repo (the selected indexed repo, or the
/// first selected source repo); [sources] carries the full selection
/// as `source_scope`. The backend's scope filter reads `repo_keys`
/// and `source_ids`; `doc_ids` is included under its own name as the
/// plan specifies, with `source_ids` mirroring it so the Qdrant
/// filter actually applies.
Map<String, dynamic> buildCodeScope({
  required String? repoKey,
  required String branch,
  String? thinkingLevel,
  required CodeExecutionMode executionMode,
  required String autonomyMode,
  required CodeSelectedSources sources,
}) {
  final repoKeys = <String>{
    if (repoKey != null && repoKey.isNotEmpty) repoKey,
    ...sources.repoKeys,
  }.toList();
  return <String, dynamic>{
    'workspace_mode': 'code',
    if (repoKey != null && repoKey.isNotEmpty) 'repo_key': repoKey,
    if (branch.isNotEmpty) 'branch': branch,
    if (thinkingLevel != null && thinkingLevel.isNotEmpty)
      'thinking_level': thinkingLevel.toLowerCase(),
    'execution_mode': executionMode.name,
    'autonomy_mode': autonomyMode,
    'source_scope': <String, dynamic>{
      'repo_keys': repoKeys,
      'doc_ids': sources.docIds.toList(),
      'source_ids': sources.docIds.toList(),
    },
  };
}

/// User-facing label for a backend `autonomy_mode` value, as shown
/// on the below-composer autonomy control.
String codeAutonomyLabel(String autonomyMode) {
  switch (autonomyMode) {
    case 'ask_all':
      return 'Request Review';
    case 'auto_workspace_writes':
      return 'Auto';
    case 'autonomous':
      return 'Turbo';
    case 'auto_read_test':
    default:
      return 'Default';
  }
}

/// The autonomy tiers offered by the below-composer popover, in
/// presentation order: (backend value, label).
const List<(String, String)> codeAutonomyTiers = [
  ('ask_all', 'Request Review'),
  ('auto_read_test', 'Default'),
  ('auto_workspace_writes', 'Auto'),
  ('autonomous', 'Turbo'),
];

/// One entry in the composer's `/` command list.
class CodeSlashCommand {
  final String command;
  final String description;

  const CodeSlashCommand({required this.command, required this.description});
}

/// Slash commands understood by the Code composer. `/plan` and
/// `/act` switch [codeExecutionModeProvider]; the rest route to
/// existing actions in the pane (compaction sheet, new chat,
/// Security sub-view).
const List<CodeSlashCommand> codeSlashCommands = [
  CodeSlashCommand(command: '/plan', description: 'Switch to Plan mode'),
  CodeSlashCommand(command: '/act', description: 'Switch to Act mode'),
  CodeSlashCommand(command: '/compact', description: 'Compact this thread'),
  CodeSlashCommand(command: '/clear', description: 'Start a new Code chat'),
  CodeSlashCommand(command: '/security', description: 'Open Security'),
  CodeSlashCommand(
    command: '/security-review',
    description: 'Audit active diff for security issues',
  ),
];
