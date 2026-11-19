import 'package:material_ui/material_ui.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/core/theme_extension.dart';

/// Displays RAG telemetry scores for an assistant message.
///
/// Shown only when the user has enabled the "Show Telemetry" toggle in the
/// chat header. Animates in on first appearance and wraps itself in
/// [AnimatedSize] so the parent layout reflows smoothly if the panel is
/// added or removed after the fact.
class ChatMessageMetrics extends StatefulWidget {
  final Map<String, dynamic> metrics;

  const ChatMessageMetrics({super.key, required this.metrics});

  @override
  State<ChatMessageMetrics> createState() => _ChatMessageMetricsState();
}

class _ChatMessageMetricsState extends State<ChatMessageMetrics> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>();

    final contextAdherence = _toDouble(widget.metrics['context_adherence'] ??
        widget.metrics['grounding_score']);
    final confidence = _toDouble(widget.metrics['confidence']);
    final generationSeconds = _toDouble(widget.metrics['generation_seconds']);

    // Token usage / cost: flattened keys from the backend metrics, with
    // a nested `usage` map accepted for older payloads. Absent usage
    // (provider reported none) shows no tile — never an estimate.
    final usage = widget.metrics['usage'];
    final usageMap =
        usage is Map ? Map<String, dynamic>.from(usage) : widget.metrics;
    final promptTokens = _toInt(usageMap['prompt_tokens']);
    final completionTokens = _toInt(usageMap['completion_tokens']);
    final totalTokens = _toInt(usageMap['total_tokens']);
    final contextWindowTokens = _toInt(usageMap['context_window_tokens']);
    final estimatedCostUsd = _toDouble(usageMap['estimated_cost_usd']);
    final hasUsage =
        promptTokens != null || completionTokens != null || totalTokens != null;

    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: Container(
        margin: EdgeInsets.only(top: 12),
        padding: EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF242424)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics_outlined,
                    size: 16, color: ext?.primaryGradientStart ?? Colors.white),
                SizedBox(width: 8),
                Text(
                  'Response Metrics',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _MetricTile(
                  label: 'Context adherence',
                  value: contextAdherence,
                  accentColor: const Color(0xFF22C55E),
                ),
                _MetricTile(
                  label: 'Confidence',
                  value: confidence,
                  accentColor: const Color(0xFFF59E0B),
                ),
                _MetricTile(
                  label: 'Generation',
                  value: generationSeconds,
                  accentColor:
                      ext?.primaryGradientStart ?? const Color(0xFF22C55E),
                  isDuration: true,
                ),
              ],
            ),
            if (hasUsage) ...[
              SizedBox(height: 12),
              _UsageTile(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens,
                contextWindowTokens: contextWindowTokens,
                estimatedCostUsd: estimatedCostUsd,
              ),
            ],
            if ((contextAdherence ?? 1.0) == 0.0 || (confidence ?? 1.0) == 0.0)
              Padding(
                padding: EdgeInsets.only(top: 12.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Color(0xFF8A8A8A)),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'A 0% score typically means the AI used its pre-trained knowledge to answer, rather than strictly citing the short retrieved snippets.',
                        style: TextStyle(
                          color: const Color(0xFF8A8A8A),
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      )
          .animate()
          .fade(duration: 300.ms)
          .slideY(begin: 0.08, end: 0, duration: 300.ms, curve: Curves.easeOut),
    );
  }

  double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }

  int? _toInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    return null;
  }
}

/// Token usage for one completion, plus its estimated cost when the
/// backend could price the model (null cost = pricing unknown, shown
/// as no cost line rather than a fabricated number).
class _UsageTile extends StatelessWidget {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? contextWindowTokens;
  final double? estimatedCostUsd;

  const _UsageTile({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.contextWindowTokens,
    required this.estimatedCostUsd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color:
                Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'TOKEN USAGE',
            style: TextStyle(
              color: Color(0xFF8A8A8A),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '${totalTokens ?? '--'} tokens',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Prompt ${promptTokens ?? '--'} · Completion ${completionTokens ?? '--'}',
            style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
          ),
          if (promptTokens != null && contextWindowTokens != null) ...[
            SizedBox(height: 4),
            Text(
              'Context ${promptTokens!} of ${contextWindowTokens!} tokens '
              '(${(promptTokens! / contextWindowTokens! * 100).round()}%)',
              style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
            ),
          ],
          if (estimatedCostUsd != null) ...[
            SizedBox(height: 4),
            Text(
              'Est. cost \$${estimatedCostUsd!.toStringAsFixed(4)}',
              style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final double? value;
  final Color accentColor;
  final bool isDuration;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.accentColor,
    this.isDuration = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color:
                Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: Color(0xFF8A8A8A),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          SizedBox(height: 10),
          if (!isDuration)
            SizedBox(
              width: double.infinity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: value ?? 0.0,
                  backgroundColor: const Color(0xFF2E2E2E),
                  valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                  color: accentColor,
                ),
              ),
            )
          else
            SizedBox(height: 4), // Placeholder to keep tile height consistent
          SizedBox(height: 8),
          Text(
            _formatValue(),
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatValue() {
    if (value == null) {
      return '--';
    }
    if (isDuration) {
      return '${value!.toStringAsFixed(2)}s';
    }
    return '${(value! * 100).round()}%';
  }
}
