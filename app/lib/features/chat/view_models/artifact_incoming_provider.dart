import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_quick_actions.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

/// A rewrite quick action (Fix Bugs, Add Logs, Comments) fired from
/// the artifact panel, waiting for its reply. The panel sets this
/// when the action is sent; the reply is the first assistant message
/// after the artifact's own message in the same thread.
class PendingQuickAction {
  /// The artifact the action was fired from.
  final OpenCodeArtifact open;

  /// The action that was sent.
  final ArtifactQuickAction action;

  const PendingQuickAction({required this.open, required this.action});

  @override
  bool operator ==(Object other) =>
      other is PendingQuickAction &&
      other.open == open &&
      other.action == action;

  @override
  int get hashCode => Object.hash(open, action);
}

/// The quick action currently awaiting its reply, if any. Set by
/// the artifact panel; consumed (cleared) by the panel once the
/// reply has arrived and been offered or dismissed.
final pendingQuickActionProvider =
    StateProvider<PendingQuickAction?>((ref) => null);

/// The artifacts of the quick action's reply, or null while there
/// is no completed reply to consider.
///
/// The reply is the FIRST assistant message after the artifact's
/// source message: chat is sequential, so that message is the answer
/// to the quick action's prompt, and later messages belong to other
/// exchanges. A reply that is still streaming does not count — its
/// code can still change — and neither does a different thread.
List<CodeArtifact>? quickActionReplyArtifacts(
  ChatState state, {
  required String? threadId,
  required int afterMessageIndex,
}) {
  if (threadId != state.threadId) return null;
  for (var i = afterMessageIndex + 1; i < state.messages.length; i++) {
    final message = state.messages[i];
    if (message.role != 'assistant') continue;
    if (message.isStreaming) return null;
    return extractCodeArtifacts(message.content);
  }
  return null;
}

/// The pending quick action's reply artifacts, resolved live from
/// chat state. Null while no action is pending, while a different
/// artifact is open, or while the reply has not completed. The
/// panel consumes the first non-null value exactly once.
final quickActionReplyProvider = Provider<List<CodeArtifact>?>((ref) {
  final pending = ref.watch(pendingQuickActionProvider);
  if (pending == null) return null;
  final open = ref.watch(openCodeArtifactProvider);
  if (open != pending.open) return null;
  final messageIndex = pending.open.messageIndex;
  if (messageIndex == null) return null;
  final state = ref.watch(chatViewModelProvider);
  return quickActionReplyArtifacts(
    state,
    threadId: pending.open.threadId,
    afterMessageIndex: messageIndex,
  );
});
