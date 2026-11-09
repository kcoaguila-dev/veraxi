import 'package:flutter/material.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/views/widgets/tool_event_card.dart';

class ChatActivityDisclosure extends StatefulWidget {
  const ChatActivityDisclosure({
    super.key,
    required this.activity,
    this.isStreaming = false,
  });

  final List<ActivityStep> activity;
  final bool isStreaming;

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
    final summary = isRunning && widget.isStreaming
        ? 'Working through ${widget.activity.length} steps'
        : hasError
            ? 'Activity completed with an issue'
            : 'Worked through ${widget.activity.length} steps';

    return Semantics(
      container: true,
      label: 'Activity details',
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _accentColor(hasError, isRunning).withValues(alpha: 0.28),
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
                      if (!isRunning && !hasError)
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
                  padding: const EdgeInsets.fromLTRB(14, 0, 10, 10),
                  child: Column(
                    children: [
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              isError
                  ? Icons.error_outline_rounded
                  : isRunning
                      ? Icons.radio_button_checked_rounded
                      : Icons.check_circle_outline_rounded,
              size: 14,
              color: statusColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Step ${step.number}: ${step.name}',
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
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      children: [
                        for (final event in step.toolEvents)
                          ToolEventCard(event: event),
                      ],
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
