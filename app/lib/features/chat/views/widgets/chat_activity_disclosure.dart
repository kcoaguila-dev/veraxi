import 'package:flutter/material.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/views/widgets/tool_event_card.dart';

class ChatActivityDisclosure extends StatefulWidget {
  const ChatActivityDisclosure({
    super.key,
    required this.activity,
    this.isStreaming = false,
    this.reasoning,
    this.reasoningDurationSeconds,
  });

  final List<ActivityStep> activity;
  final bool isStreaming;
  final String? reasoning;
  final double? reasoningDurationSeconds;

  @override
  State<ChatActivityDisclosure> createState() => _ChatActivityDisclosureState();
}

class _ChatActivityDisclosureState extends State<ChatActivityDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final completed = widget.activity
        .where((step) => step.status == ActivityStepStatus.complete)
        .length;
    final hasError =
        widget.activity.any((step) => step.status == ActivityStepStatus.error);
    final isRunning = widget.activity
        .any((step) => step.status == ActivityStepStatus.running);
    final hasReasoning = widget.reasoning?.isNotEmpty ?? false;
    final summary = isRunning && widget.isStreaming
        ? 'Working through ${widget.activity.length} steps'
        : hasError
            ? 'Activity completed with an issue'
            : widget.activity.isNotEmpty
                ? 'Worked through ${widget.activity.length} '
                    '${widget.activity.length == 1 ? 'step' : 'steps'}'
                : 'Thought process';

    return Semantics(
      container: true,
      label: 'Activity details',
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.025),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        size: 17,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        hasError
                            ? Icons.warning_amber_rounded
                            : isRunning && widget.isStreaming
                                ? Icons.sync_rounded
                                : Icons.check_circle_outline_rounded,
                        size: 15,
                        color: _accentColor(hasError, isRunning),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          summary,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      if (widget.activity.isNotEmpty && !isRunning && !hasError)
                        Text(
                          '$completed/${widget.activity.length}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white54,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: [
                      if (hasReasoning)
                        _ReasoningView(
                          reasoning: widget.reasoning!,
                          durationSeconds: widget.reasoningDurationSeconds,
                        ),
                      for (final step in widget.activity)
                        _ActivityStepView(step: step),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _accentColor(bool hasError, bool isRunning) {
    if (hasError) return Colors.orangeAccent;
    if (isRunning && widget.isStreaming) return Colors.lightBlueAccent;
    return Colors.greenAccent.shade400;
  }
}

class _ReasoningView extends StatelessWidget {
  const _ReasoningView({
    required this.reasoning,
    this.durationSeconds,
  });

  final String reasoning;
  final double? durationSeconds;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _TimelineMarker(
            color: Colors.purpleAccent,
            icon: Icons.psychology_outlined,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  durationSeconds != null
                      ? 'Thought process · '
                          '${durationSeconds!.toStringAsFixed(1)}s'
                      : 'Thought process',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  reasoning,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: Colors.white54,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineMarker extends StatelessWidget {
  const _TimelineMarker({
    required this.color,
    required this.icon,
  });

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 12, color: color),
    );
  }
}

class _ActivityStepView extends StatelessWidget {
  const _ActivityStepView({required this.step});

  final ActivityStep step;

  @override
  Widget build(BuildContext context) {
    final isError = step.status == ActivityStepStatus.error;
    final isRunning = step.status == ActivityStepStatus.running;
    final statusColor = isError
        ? Colors.orangeAccent
        : isRunning
            ? Colors.lightBlueAccent
            : Colors.greenAccent.shade400;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TimelineMarker(
            color: statusColor,
            icon: isError
                ? Icons.error_outline_rounded
                : isRunning
                    ? Icons.radio_button_checked_rounded
                    : Icons.check_rounded,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                if (step.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      step.description,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                if (step.summary != null && step.summary!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      step.summary!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (step.toolEvents.isNotEmpty)
                  Column(
                    children: [
                      const SizedBox(height: 6),
                      for (final event in step.toolEvents)
                        ToolEventCard(event: event),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
