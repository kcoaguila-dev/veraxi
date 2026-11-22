import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Top-level workspace mode in the unified `[ Chat | Code ]` shell.
enum WorkspaceMode { chat, code }

/// Sub-views surfaced inside the Code workbench tab.
enum CodeSubView {
  vulnIntel,
  repoXray,
  securityFeed,
  corpusBriefing,
  dbtLineage,
}

/// Active workspace mode (`Chat` vs `Code`), preserved across tab switches.
final workspaceModeProvider =
    StateProvider<WorkspaceMode>((ref) => WorkspaceMode.chat);

/// Active sub-view inside `Code` mode.
final codeSubViewProvider =
    StateProvider<CodeSubView>((ref) => CodeSubView.vulnIntel);

/// Number of active CISA KEV alerts surfaced as a sidebar indicator dot/pill.
final activeKevCountProvider = StateProvider<int>((ref) => 0);

/// Currently scoped indexed repository label in the Code sidebar.
final selectedIndexedRepoProvider =
    StateProvider<String>((ref) => 'veraxi/backend');
